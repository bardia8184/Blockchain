// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MultiSigVault {
    // --- Owners ---
    address[] public owners;
    mapping(address => bool) public isOwner;
    uint256 public immutable required;

    // --- Transactions ---
    struct Transaction {
        address to;
        uint256 value;
        bool executed;
        uint256 approvalCount;
    }

    Transaction[] public transactions;

    // txId => owner => approved?
    mapping(uint256 => mapping(address => bool)) public approvedBy;

    // --- Events ---
    event FundsReceived(address indexed from, uint256 amount);
    event Submitted(uint256 indexed txId, address indexed to, uint256 value);
    event Approved(uint256 indexed txId, address indexed owner);
    event Revoked(uint256 indexed txId, address indexed owner);
    event Executed(uint256 indexed txId, address indexed executor, uint256 value);

    // --- Errors ---
    error NotOwner();
    error OwnersRequired();
    error InvalidRequired();
    error InvalidOwner();
    error DuplicateOwner();
    error TxDoesNotExist(uint256 txId);
    error AlreadyExecuted(uint256 txId);
    error AlreadyApproved(uint256 txId);
    error NotApproved(uint256 txId);
    error NotEnoughApprovals(uint256 have, uint256 needed);
    error InsufficientBalance(uint256 have, uint256 needed);
    error TransferFailed();

    // --- Modifiers ---
    modifier onlyOwner() {
        if (!isOwner[msg.sender]) revert NotOwner();
        _;
    }

    modifier txExists(uint256 _txId) {
        if (_txId >= transactions.length) revert TxDoesNotExist(_txId);
        _;
    }

    modifier notExecuted(uint256 _txId) {
        if (transactions[_txId].executed) revert AlreadyExecuted(_txId);
        _;
    }

    constructor(address[] memory _owners, uint256 _required) {
        if (_owners.length == 0) revert OwnersRequired();
        if (_required == 0 || _required > _owners.length) revert InvalidRequired();

        for (uint256 i = 0; i < _owners.length; i++) {
            address owner = _owners[i];
            if (owner == address(0)) revert InvalidOwner();
            if (isOwner[owner]) revert DuplicateOwner();

            isOwner[owner] = true;
            owners.push(owner);
        }

        required = _required;
    }

    // accept plain ETH transfers into the vault
    receive() external payable {
        emit FundsReceived(msg.sender, msg.value);
    }

    function submit(address _to, uint256 _value) external onlyOwner returns (uint256 txId) {
        if (_to == address(0)) revert InvalidOwner();

        transactions.push(Transaction({to: _to, value: _value, executed: false, approvalCount: 0}));

        txId = transactions.length - 1;
        emit Submitted(txId, _to, _value);
    }

    function approve(uint256 _txId) external onlyOwner txExists(_txId) notExecuted(_txId) {
        if (approvedBy[_txId][msg.sender]) revert AlreadyApproved(_txId);

        approvedBy[_txId][msg.sender] = true;
        transactions[_txId].approvalCount += 1;

        emit Approved(_txId, msg.sender);
    }

    function revoke(uint256 _txId) external onlyOwner txExists(_txId) notExecuted(_txId) {
        if (!approvedBy[_txId][msg.sender]) revert NotApproved(_txId);

        approvedBy[_txId][msg.sender] = false;
        transactions[_txId].approvalCount -= 1;

        emit Revoked(_txId, msg.sender);
    }

    function execute(uint256 _txId) external onlyOwner txExists(_txId) notExecuted(_txId) {
        Transaction storage transaction = transactions[_txId];

        if (transaction.approvalCount < required) {
            revert NotEnoughApprovals(transaction.approvalCount, required);
        }
        if (address(this).balance < transaction.value) {
            revert InsufficientBalance(address(this).balance, transaction.value);
        }

        transaction.executed = true; // EFFECT
        emit Executed(_txId, msg.sender, transaction.value);

        (bool success,) = transaction.to.call{value: transaction.value}(""); // INTERACTION
        if (!success) revert TransferFailed();
    }

    // --- Views ---
    function ownerCount() external view returns (uint256) {
        return owners.length;
    }

    function transactionCount() external view returns (uint256) {
        return transactions.length;
    }

    function vaultBalance() external view returns (uint256) {
        return address(this).balance;
    }
}
