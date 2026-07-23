// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract Escrow {
    // --- Roles ---
    address public immutable buyer;
    address public immutable seller;
    address public immutable arbiter;

    // --- Timing ---
    uint public immutable timeoutPeriod;   // seconds the buyer has to confirm
    uint public deliveryDeadline;          // set when funds are deposited

    // --- State machine ---
    enum State { AWAITING_PAYMENT, AWAITING_DELIVERY, COMPLETE, REFUNDED, CANCELLED }
    State public currentState;

    // --- Events ---
    event Deposited(address indexed buyer, uint amount, uint deadline);
    event Delivered(address indexed seller, uint amount);
    event Refunded(address indexed buyer, uint amount);
    event Cancelled(address indexed by);
    event TimeoutClaimed(address indexed seller, uint amount);

    // --- Errors ---
    error NotBuyer();
    error NotSeller();
    error NotArbiter();
    error NotParty();
    error InvalidState(State expected, State actual);
    error NoFundsSent();
    error InvalidAddress();
    error InvalidTimeout();
    error TooEarly(uint deadline, uint currentTime);
    error TransferFailed();

    // --- Modifiers ---
    modifier onlyBuyer() {
        if (msg.sender != buyer) revert NotBuyer();
        _;
    }

    modifier onlySeller() {
        if (msg.sender != seller) revert NotSeller();
        _;
    }

    modifier onlyArbiter() {
        if (msg.sender != arbiter) revert NotArbiter();
        _;
    }

    modifier onlyParty() {
        if (msg.sender != buyer && msg.sender != seller) revert NotParty();
        _;
    }

    modifier inState(State expected) {
        if (currentState != expected) revert InvalidState(expected, currentState);
        _;
    }

    constructor(address _seller, address _arbiter, uint _timeoutPeriod) {
        if (_seller == address(0) || _arbiter == address(0)) revert InvalidAddress();
        if (_timeoutPeriod == 0) revert InvalidTimeout();
        buyer = msg.sender;
        seller = _seller;
        arbiter = _arbiter;
        timeoutPeriod = _timeoutPeriod;
        currentState = State.AWAITING_PAYMENT;
    }

    function deposit() external payable onlyBuyer inState(State.AWAITING_PAYMENT) {
        if (msg.value == 0) revert NoFundsSent();
        currentState = State.AWAITING_DELIVERY;
        deliveryDeadline = block.timestamp + timeoutPeriod;
        emit Deposited(msg.sender, msg.value, deliveryDeadline);
    }

    function confirmDelivery() external onlyBuyer inState(State.AWAITING_DELIVERY) {
        uint amount = address(this).balance;
        currentState = State.COMPLETE;
        emit Delivered(seller, amount);
        (bool success, ) = seller.call{value: amount}("");
        if (!success) revert TransferFailed();
    }

    function refundBuyer() external onlyArbiter inState(State.AWAITING_DELIVERY) {
        uint amount = address(this).balance;
        currentState = State.REFUNDED;
        emit Refunded(buyer, amount);
        (bool success, ) = buyer.call{value: amount}("");
        if (!success) revert TransferFailed();
    }

    function claimTimeout() external onlySeller inState(State.AWAITING_DELIVERY) {
        if (block.timestamp < deliveryDeadline) {
            revert TooEarly(deliveryDeadline, block.timestamp);
        }
        uint amount = address(this).balance;
        currentState = State.COMPLETE;
        emit TimeoutClaimed(seller, amount);
        (bool success, ) = seller.call{value: amount}("");
        if (!success) revert TransferFailed();
    }

    function cancel() external onlyParty inState(State.AWAITING_PAYMENT) {
        currentState = State.CANCELLED;
        emit Cancelled(msg.sender);
    }

    function contractBalance() external view returns (uint) {
        return address(this).balance;
    }
}