// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {StakingRewards} from "../src/StakingRewards.sol";
import {MyToken} from "../src/MyToken.sol";

contract StakingRewardsTest is Test {
    StakingRewards staking;
    MyToken stakingToken;
    MyToken rewardToken;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address stranger = makeAddr("stranger");

    uint256 constant DURATION = 7 days; // 604,800 seconds
    uint256 constant REWARD_AMOUNT = 604_800 ether; // => exactly 1 token/second
    uint256 constant STAKE = 100 ether;

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);

    function setUp() public {
        vm.startPrank(owner);
        stakingToken = new MyToken();
        rewardToken = new MyToken();
        staking = new StakingRewards(address(stakingToken), address(rewardToken), DURATION);

        // fund users with staking tokens
        require(stakingToken.transfer(alice, 1000 ether), "fund alice");
        require(stakingToken.transfer(bob, 1000 ether), "fund bob");

        // owner approves the staking contract to pull reward tokens
        rewardToken.approve(address(staking), type(uint256).max);
        vm.stopPrank();

        // users approve the staking contract to pull their stake
        vm.prank(alice);
        stakingToken.approve(address(staking), type(uint256).max);
        vm.prank(bob);
        stakingToken.approve(address(staking), type(uint256).max);
    }

    function _startRewards() internal {
        vm.prank(owner);
        staking.notifyRewardAmount(REWARD_AMOUNT);
    }

    // ---------- deployment ----------

    function test_InitialState() public view {
        assertEq(address(staking.stakingToken()), address(stakingToken));
        assertEq(address(staking.rewardToken()), address(rewardToken));
        assertEq(staking.rewardsDuration(), DURATION);
        assertEq(staking.owner(), owner);
        assertEq(staking.totalStaked(), 0);
        assertEq(staking.rewardRate(), 0);
    }

    function test_RevertWhen_StakingTokenIsZero() public {
        vm.expectRevert(StakingRewards.InvalidAddress.selector);
        new StakingRewards(address(0), address(rewardToken), DURATION);
    }

    function test_RevertWhen_TokensAreIdentical() public {
        vm.expectRevert(StakingRewards.SameToken.selector);
        new StakingRewards(address(stakingToken), address(stakingToken), DURATION);
    }

    function test_RevertWhen_DurationIsZero() public {
        vm.expectRevert(StakingRewards.InvalidDuration.selector);
        new StakingRewards(address(stakingToken), address(rewardToken), 0);
    }

    // ---------- funding rewards ----------

    function test_NotifyRewardSetsRateAndDeadline() public {
        _startRewards();

        assertEq(staking.rewardRate(), 1 ether); // 1 token per second
        assertEq(staking.periodFinish(), block.timestamp + DURATION);
        assertEq(rewardToken.balanceOf(address(staking)), REWARD_AMOUNT);
    }

    function test_RevertWhen_StrangerNotifiesReward() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        staking.notifyRewardAmount(REWARD_AMOUNT);
    }

    function test_RevertWhen_NotifyingZeroReward() public {
        vm.prank(owner);
        vm.expectRevert(StakingRewards.ZeroAmount.selector);
        staking.notifyRewardAmount(0);
    }

    // ---------- staking ----------

    function test_StakeMovesTokensAndUpdatesBalances() public {
        _startRewards();

        vm.expectEmit(true, false, false, true);
        emit Staked(alice, STAKE);

        vm.prank(alice);
        staking.stake(STAKE);

        assertEq(staking.balanceOf(alice), STAKE);
        assertEq(staking.totalStaked(), STAKE);
        assertEq(stakingToken.balanceOf(address(staking)), STAKE);
        assertEq(stakingToken.balanceOf(alice), 1000 ether - STAKE);
    }

    function test_RevertWhen_StakingZero() public {
        _startRewards();
        vm.prank(alice);
        vm.expectRevert(StakingRewards.ZeroAmount.selector);
        staking.stake(0);
    }

    // ---------- reward accrual ----------

    function test_SoleStakerEarnsFullRate() public {
        _startRewards();

        vm.prank(alice);
        staking.stake(STAKE);

        vm.warp(block.timestamp + 100);

        // 100 seconds at 1 token/second, alice is the only staker
        assertEq(staking.earned(alice), 100 ether);
    }

    function test_NoRewardsBeforeStaking() public {
        _startRewards();
        vm.warp(block.timestamp + 100);
        assertEq(staking.earned(alice), 0);
    }

    /// Alice stakes alone for 100s, then Bob joins with an equal stake for 100s.
    /// Alice: 100 + 50 = 150.  Bob: 50.  Total emitted: 200 tokens over 200s.
    function test_RewardsSplitProportionallyWhenSecondStakerJoins() public {
        _startRewards();

        vm.prank(alice);
        staking.stake(STAKE);

        vm.warp(block.timestamp + 100);

        vm.prank(bob);
        staking.stake(STAKE);

        vm.warp(block.timestamp + 100);

        assertEq(staking.earned(alice), 150 ether);
        assertEq(staking.earned(bob), 50 ether);
    }

    /// A larger stake earns proportionally more over the same window.
    function test_LargerStakeEarnsMore() public {
        _startRewards();

        vm.prank(alice);
        staking.stake(300 ether);
        vm.prank(bob);
        staking.stake(100 ether);

        vm.warp(block.timestamp + 100);

        assertEq(staking.earned(alice), 75 ether); // 3/4 of 100
        assertEq(staking.earned(bob), 25 ether); // 1/4 of 100
    }

    function test_RewardsStopAfterPeriodFinish() public {
        _startRewards();

        vm.prank(alice);
        staking.stake(STAKE);

        vm.warp(block.timestamp + DURATION);
        uint256 earnedAtEnd = staking.earned(alice);

        vm.warp(block.timestamp + 30 days);
        assertEq(staking.earned(alice), earnedAtEnd);
    }

    function test_SoleStakerEarnsEntireRewardPool() public {
        _startRewards();

        vm.prank(alice);
        staking.stake(STAKE);

        vm.warp(block.timestamp + DURATION);

        assertEq(staking.earned(alice), REWARD_AMOUNT);
    }

    // ---------- claiming ----------

    function test_ClaimRewardTransfersAndResets() public {
        _startRewards();

        vm.prank(alice);
        staking.stake(STAKE);

        vm.warp(block.timestamp + 100);

        vm.expectEmit(true, false, false, true);
        emit RewardPaid(alice, 100 ether);

        vm.prank(alice);
        staking.claimReward();

        assertEq(rewardToken.balanceOf(alice), 100 ether);
        assertEq(staking.earned(alice), 0);
    }

    function test_RevertWhen_ClaimingWithNoRewards() public {
        _startRewards();
        vm.prank(alice);
        vm.expectRevert(StakingRewards.NoRewardToClaim.selector);
        staking.claimReward();
    }

    function test_ClaimingTwiceInARowFails() public {
        _startRewards();

        vm.prank(alice);
        staking.stake(STAKE);
        vm.warp(block.timestamp + 100);

        vm.startPrank(alice);
        staking.claimReward();

        vm.expectRevert(StakingRewards.NoRewardToClaim.selector);
        staking.claimReward();
        vm.stopPrank();
    }

    // ---------- withdrawing ----------

    function test_WithdrawReturnsStakeAndKeepsRewards() public {
        _startRewards();

        vm.prank(alice);
        staking.stake(STAKE);

        vm.warp(block.timestamp + 100);

        vm.prank(alice);
        staking.withdraw(STAKE);

        assertEq(staking.balanceOf(alice), 0);
        assertEq(staking.totalStaked(), 0);
        assertEq(stakingToken.balanceOf(alice), 1000 ether);
        assertEq(staking.earned(alice), 100 ether); // rewards survive withdrawal
    }

    function test_PartialWithdrawKeepsEarningOnRemainder() public {
        _startRewards();

        vm.prank(alice);
        staking.stake(STAKE);

        vm.warp(block.timestamp + 100);

        vm.prank(alice);
        staking.withdraw(50 ether);

        vm.warp(block.timestamp + 100);

        // 100 earned while fully staked, then 100 more as the sole staker
        assertEq(staking.earned(alice), 200 ether);
        assertEq(staking.balanceOf(alice), 50 ether);
    }

    function test_RevertWhen_WithdrawingMoreThanStaked() public {
        _startRewards();

        vm.prank(alice);
        staking.stake(STAKE);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingRewards.InsufficientStake.selector, uint256(200 ether), STAKE));
        staking.withdraw(200 ether);
    }

    function test_ExitWithdrawsAndClaimsInOneCall() public {
        _startRewards();

        vm.prank(alice);
        staking.stake(STAKE);

        vm.warp(block.timestamp + 100);

        vm.prank(alice);
        staking.exit();

        assertEq(staking.balanceOf(alice), 0);
        assertEq(stakingToken.balanceOf(alice), 1000 ether);
        assertEq(rewardToken.balanceOf(alice), 100 ether);
        assertEq(staking.earned(alice), 0);
    }

    // ---------- duration management ----------

    function test_OwnerCanChangeDurationAfterPeriodEnds() public {
        _startRewards();
        vm.warp(block.timestamp + DURATION + 1);

        vm.prank(owner);
        staking.setRewardsDuration(14 days);

        assertEq(staking.rewardsDuration(), 14 days);
    }

    function test_RevertWhen_ChangingDurationDuringActivePeriod() public {
        _startRewards();

        uint256 finish = staking.periodFinish();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(StakingRewards.RewardPeriodActive.selector, finish));
        staking.setRewardsDuration(14 days);
    }

    function test_RevertWhen_StrangerChangesDuration() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        staking.setRewardsDuration(14 days);
    }
}
