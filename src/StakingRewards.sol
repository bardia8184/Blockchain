// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract StakingRewards is Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardToken;

    uint256 public rewardsDuration;
    uint256 public rewardRate; // reward tokens distributed per second
    uint256 public periodFinish; // when the current reward period ends
    uint256 public lastUpdateTime; // last time the accumulator was refreshed
    uint256 public rewardPerTokenStored; // the accumulator

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    uint256 public totalStaked;
    mapping(address => uint256) public balanceOf;

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);
    event RewardAdded(uint256 reward, uint256 periodFinish);
    event RewardsDurationUpdated(uint256 duration);

    error InvalidAddress();
    error SameToken();
    error InvalidDuration();
    error ZeroAmount();
    error InsufficientStake(uint256 requested, uint256 available);
    error RewardPeriodActive(uint256 periodFinish);
    error RewardTooHigh(uint256 rate, uint256 maxRate);
    error NoRewardToClaim();

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();

        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    constructor(address _stakingToken, address _rewardToken, uint256 _rewardsDuration) Ownable(msg.sender) {
        if (_stakingToken == address(0) || _rewardToken == address(0)) revert InvalidAddress();
        if (_stakingToken == _rewardToken) revert SameToken();
        if (_rewardsDuration == 0) revert InvalidDuration();

        stakingToken = IERC20(_stakingToken);
        rewardToken = IERC20(_rewardToken);
        rewardsDuration = _rewardsDuration;
    }

    // ---------- views ----------

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) {
            return rewardPerTokenStored;
        }
        uint256 elapsed = lastTimeRewardApplicable() - lastUpdateTime;
        return rewardPerTokenStored + (elapsed * rewardRate * 1e18) / totalStaked;
    }

    function earned(address account) public view returns (uint256) {
        uint256 owedPerToken = rewardPerToken() - userRewardPerTokenPaid[account];
        return (balanceOf[account] * owedPerToken) / 1e18 + rewards[account];
    }

    // ---------- user actions ----------

    function stake(uint256 amount) external updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();

        totalStaked += amount;
        balanceOf[msg.sender] += amount;
        emit Staked(msg.sender, amount);

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    function withdraw(uint256 amount) public updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();
        if (amount > balanceOf[msg.sender]) {
            revert InsufficientStake(amount, balanceOf[msg.sender]);
        }

        totalStaked -= amount;
        balanceOf[msg.sender] -= amount;
        emit Withdrawn(msg.sender, amount);

        stakingToken.safeTransfer(msg.sender, amount);
    }

    function claimReward() public updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward == 0) revert NoRewardToClaim();

        rewards[msg.sender] = 0;
        emit RewardPaid(msg.sender, reward);

        rewardToken.safeTransfer(msg.sender, reward);
    }

    function exit() external {
        withdraw(balanceOf[msg.sender]);
        if (rewards[msg.sender] > 0) {
            claimReward();
        }
    }

    // ---------- owner ----------

    function notifyRewardAmount(uint256 reward) external onlyOwner updateReward(address(0)) {
        if (reward == 0) revert ZeroAmount();

        rewardToken.safeTransferFrom(msg.sender, address(this), reward);

        if (block.timestamp >= periodFinish) {
            rewardRate = reward / rewardsDuration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (reward + leftover) / rewardsDuration;
        }

        uint256 balance = rewardToken.balanceOf(address(this));
        uint256 maxRate = balance / rewardsDuration;
        if (rewardRate > maxRate) revert RewardTooHigh(rewardRate, maxRate);

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;

        emit RewardAdded(reward, periodFinish);
    }

    function setRewardsDuration(uint256 _rewardsDuration) external onlyOwner {
        if (block.timestamp < periodFinish) revert RewardPeriodActive(periodFinish);
        if (_rewardsDuration == 0) revert InvalidDuration();

        rewardsDuration = _rewardsDuration;
        emit RewardsDurationUpdated(_rewardsDuration);
    }
}
