// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {TestToken} from "../src/TestToken.sol";
import {StakingRewards} from "../src/StakingRewards.sol";

contract DeployStaking is Script {
    uint constant DURATION = 7 days;
    uint constant REWARD_POOL = 604_800 ether; // exactly 1 token per second
    uint constant STAKE_SUPPLY = 1_000_000 ether;

    function run() external {
        vm.startBroadcast();

        TestToken stakeToken = new TestToken("Stake Token", "STK", STAKE_SUPPLY);
        TestToken rewardToken = new TestToken("Reward Token", "RWD", REWARD_POOL);

        StakingRewards staking =
            new StakingRewards(address(stakeToken), address(rewardToken), DURATION);

        rewardToken.approve(address(staking), REWARD_POOL);
        staking.notifyRewardAmount(REWARD_POOL);

        vm.stopBroadcast();

        console.log("StakeToken: ", address(stakeToken));
        console.log("RewardToken:", address(rewardToken));
        console.log("Staking:    ", address(staking));
    }
}