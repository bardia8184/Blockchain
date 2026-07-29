# Blockchain Portfolio

> **Live full-stack dApps built on these contracts:**
> - [Staking-Dapp](https://github.com/bardia8184/Staking-Dapp) ([live demo](https://staking-dapp-indol.vercel.app)) — stake, earn, claim, with live reward accrual
> - [MultiSig-Dapp](https://github.com/bardia8184/MultiSig-Dapp) ([live demo](https://multi-sig-dapp.vercel.app)) — propose, approve, and execute vault transactions

Production-style Solidity contracts built with Foundry, with full test coverage
including negative cases for every access-control rule, state transition, and
arithmetic guarantee.

**Stack:** Solidity 0.8.20+ · Foundry · OpenZeppelin

```bash
forge install && forge build && forge test
```

**90 tests · 4 contracts · 0 failures**

---

## Contracts

### `Escrow.sol` — Trust-minimised escrow with dispute resolution

A buyer deposits funds held by the contract until delivery is confirmed. A neutral
arbiter can refund the buyer during a dispute, and a timeout prevents funds from
being locked forever if the buyer disappears.

**Roles:** `buyer` · `seller` · `arbiter` — all `immutable`, so they cannot be
swapped after deployment.

```
AWAITING_PAYMENT ──deposit()──▶ AWAITING_DELIVERY ──confirmDelivery()──▶ COMPLETE
       │                                │
       │                                ├──refundBuyer()───▶ REFUNDED
       │                                └──claimTimeout()──▶ COMPLETE
       └──cancel()──▶ CANCELLED
```

Every function is gated on the current state, so the escrow can pay out exactly
once. Terminal states close all remaining exits.

**Design decisions**

- *Timeout releases funds to the seller.* If an inactive buyer meant funds froze
  permanently, any buyer could grief a seller who had already shipped. The buyer's
  protection is the arbiter, available at any point before the deadline.
- *The buyer can never unilaterally reclaim deposited funds*, which would allow
  receiving goods and clawing back payment. `cancel()` is restricted to
  `AWAITING_PAYMENT`, when nothing is at stake.

### `MultiSigVault.sol` — M-of-N multi-signature vault

Funds move only when `required` owners independently approve. A single compromised
key cannot move any money.

`submit()` proposes a payment → owners `approve()` → any owner `execute()`s once the
threshold is met. Approvals can be withdrawn with `revoke()` before execution.

**Design decisions**

- *Owners are stored in both an array and a mapping* — the mapping gives O(1)
  permission checks on every call, the array makes the owner set enumerable for a
  frontend. Mappings alone cannot be iterated.
- *`approvalCount` is maintained incrementally* rather than recomputed by looping
  over owners, so execution cost does not grow with the number of owners.
- *Only owners may execute.* Some multisigs allow anyone to execute an approved
  transaction; restricting it is the tighter choice.

### `TokenSale.sol` — Fixed-rate token sale

Buyers send ETH and receive ERC-20 tokens at a fixed rate for a fixed window. The
owner withdraws proceeds and can recover unsold tokens once the sale closes.

**Design decisions**

- *All token movements use OpenZeppelin's `SafeERC20`.* A raw `transfer` ignores the
  return value, and some major tokens (notably USDT) return no value at all, which
  breaks naive integrations. `safeTransfer` handles both cases.
- *Unsold tokens can only be recovered after the sale ends*, so the owner cannot
  withdraw supply mid-sale and strand buyers.
- *Assumes an 18-decimal token.* `msg.value * rate` relies on ETH and the token
  sharing the same scale; a 6-decimal token such as USDC would need adjustment.

### `StakingRewards.sol` — Time-weighted staking rewards

Users stake one token and earn a second token proportionally to both stake size and
time staked. Implements the Synthetix reward-per-token algorithm.

**The core mechanism.** Rewards accrue continuously across many stakers, so crediting
each user in a loop would be unbounded in gas and would break as the contract grew.
Instead the contract tracks one global accumulator — how much reward a *single staked
token* has earned since launch — plus one snapshot per user, taken at their last
interaction. A user's rewards are then:

```
balance × (accumulator_now − accumulator_at_their_last_interaction)
```

Constant cost per user, no iteration, correct for any number of stakers.

The accumulator is scaled by `1e18` to preserve precision under integer division,
and `updateReward` settles a user's rewards *before* any balance change so that a new
deposit never retroactively earns on time it was not staked.

**Design decisions**

- *Staking and reward tokens must differ.* The solvency check reads the contract's
  reward-token balance; if the tokens were identical that balance would include
  staked principal, and the contract could pay out user deposits as rewards.
- *Topping up mid-period folds undistributed rewards into the new rate*, so users
  never lose rewards that were already promised.
- *`lastTimeRewardApplicable()` caps accrual at `periodFinish`*, preventing the
  contract from accruing rewards it does not hold.

---

## Security

All contracts follow **Checks-Effects-Interactions**: state is updated before any
external call, so a re-entrant call finds the guard already closed. No
`ReentrancyGuard` is required — correct ordering is the primary defence.

- Custom errors throughout, several carrying context (`InvalidState(expected, actual)`,
  `NotEnoughApprovals(have, needed)`, `TooEarly(deadline, now)`) for precise debugging
  and clearer frontend messages.
- Zero-address validation on every address input.
- ETH sent via `call` with an explicit success check; tokens via `SafeERC20`.
- Values that must never change are `immutable`.
- `block.timestamp` is used only for coarse, multi-day deadlines, where the few
  seconds of validator influence are immaterial.

**Known limitation:** `StakingRewards.RewardTooHigh` is a defensive invariant rather
than a reachable branch — reward tokens are pulled in before the rate is computed, so
the contract's balance always covers what it just promised. It is retained to guard
against future changes to the funding flow, and is deliberately untested rather than
covered by a contrived test.

---

## Tests

90 tests, all passing. The majority assert that invalid actions **revert** —
verifying what the contracts refuse is the point.

| Test | Guarantee |
|---|---|
| `test_RevertWhen_SingleOwnerTriesToExecute` | One owner alone cannot move vault funds, and no ETH leaves |
| `test_RevokeCanBlockExecution` | Withdrawing approval prevents a previously-approved payment |
| `test_RevertWhen_ExecutingTwice` | A vault transaction cannot pay out twice |
| `test_RevertWhen_ConfirmingTwice` | Escrow funds cannot be released twice |
| `test_SellerCanClaimAfterDeadline` | Timeout releases funds, verified via `vm.warp` |
| `test_RewardsSplitProportionallyWhenSecondStakerJoins` | Two stakers joining at different times receive exactly 150 / 50 of 200 tokens emitted |
| `test_WithdrawReturnsStakeAndKeepsRewards` | Unstaking never forfeits already-earned rewards |
| `test_RewardsStopAfterPeriodFinish` | Accrual halts at the deadline, so the contract cannot owe more than it holds |
| `test_CanBuyExactlyAllRemainingTokens` | Boundary case: the final token is purchasable |

Reward-period parameters are chosen to make the arithmetic exact — a 604,800-token
pool over 604,800 seconds gives a rate of precisely 1 token per second, so any
rounding error surfaces as a test failure rather than hiding in an approximation.