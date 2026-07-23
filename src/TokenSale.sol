// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract TokenSale is Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    uint public immutable rate;      // tokens per 1 ETH
    uint public immutable saleEnd;

    uint public totalRaised;
    mapping(address => uint) public contributions;

    event TokensPurchased(address indexed buyer, uint ethPaid, uint tokensReceived);
    event ProceedsWithdrawn(address indexed to, uint amount);
    event UnsoldTokensRecovered(address indexed to, uint amount);

    error SaleEnded();
    error SaleNotEnded();
    error NoEthSent();
    error InvalidAddress();
    error InvalidRate();
    error InvalidDuration();
    error NotEnoughTokensLeft(uint requested, uint available);
    error NothingToWithdraw();
    error TransferFailed();

    constructor(address _token, uint _rate, uint _duration) Ownable(msg.sender) {
        if (_token == address(0)) revert InvalidAddress();
        if (_rate == 0) revert InvalidRate();
        if (_duration == 0) revert InvalidDuration();

        token = IERC20(_token);
        rate = _rate;
        saleEnd = block.timestamp + _duration;
    }

    function buy() external payable {
        if (block.timestamp >= saleEnd) revert SaleEnded();
        if (msg.value == 0) revert NoEthSent();

        uint tokenAmount = msg.value * rate;
        uint available = token.balanceOf(address(this));
        if (tokenAmount > available) {
            revert NotEnoughTokensLeft(tokenAmount, available);
        }

        // EFFECTS
        totalRaised += msg.value;
        contributions[msg.sender] += msg.value;
        emit TokensPurchased(msg.sender, msg.value, tokenAmount);

        // INTERACTION
        token.safeTransfer(msg.sender, tokenAmount);
    }

    function withdrawProceeds() external onlyOwner {
        uint amount = address(this).balance;
        if (amount == 0) revert NothingToWithdraw();

        emit ProceedsWithdrawn(owner(), amount);

        (bool success, ) = owner().call{value: amount}("");
        if (!success) revert TransferFailed();
    }

    function recoverUnsoldTokens() external onlyOwner {
        if (block.timestamp < saleEnd) revert SaleNotEnded();

        uint amount = token.balanceOf(address(this));
        if (amount == 0) revert NothingToWithdraw();

        emit UnsoldTokensRecovered(owner(), amount);
        token.safeTransfer(owner(), amount);
    }

    function tokensRemaining() external view returns (uint) {
        return token.balanceOf(address(this));
    }

    function saleActive() external view returns (bool) {
        return block.timestamp < saleEnd;
    }
}