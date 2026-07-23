// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MultiSigVault} from "../src/MultiSigVault.sol";

contract MultiSigVaultTest is Test {
    MultiSigVault vault;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address stranger = makeAddr("stranger");
    address payee = makeAddr("payee");

    uint256 constant REQUIRED = 2; // 2-of-3
    uint256 constant FUNDING = 10 ether;
    uint256 constant PAYMENT = 1 ether;

    event FundsReceived(address indexed from, uint256 amount);
    event Submitted(uint256 indexed txId, address indexed to, uint256 value);
    event Approved(uint256 indexed txId, address indexed owner);
    event Revoked(uint256 indexed txId, address indexed owner);
    event Executed(uint256 indexed txId, address indexed executor, uint256 value);

    function setUp() public {
        address[] memory owners = new address[](3);
        owners[0] = alice;
        owners[1] = bob;
        owners[2] = carol;

        vault = new MultiSigVault(owners, REQUIRED);
        vm.deal(address(vault), FUNDING);
    }

    // helper: submit a payment as alice
    function _submitPayment() internal returns (uint256 txId) {
        vm.prank(alice);
        txId = vault.submit(payee, PAYMENT);
    }

    // ---------- deployment ----------

    function test_InitialState() public view {
        assertEq(vault.ownerCount(), 3);
        assertEq(vault.required(), REQUIRED);
        assertTrue(vault.isOwner(alice));
        assertTrue(vault.isOwner(bob));
        assertTrue(vault.isOwner(carol));
        assertFalse(vault.isOwner(stranger));
        assertEq(vault.owners(0), alice);
        assertEq(vault.vaultBalance(), FUNDING);
    }

    function test_RevertWhen_NoOwners() public {
        address[] memory empty = new address[](0);
        vm.expectRevert(MultiSigVault.OwnersRequired.selector);
        new MultiSigVault(empty, 1);
    }

    function test_RevertWhen_RequiredIsZero() public {
        address[] memory owners = new address[](1);
        owners[0] = alice;
        vm.expectRevert(MultiSigVault.InvalidRequired.selector);
        new MultiSigVault(owners, 0);
    }

    function test_RevertWhen_RequiredExceedsOwnerCount() public {
        address[] memory owners = new address[](2);
        owners[0] = alice;
        owners[1] = bob;
        vm.expectRevert(MultiSigVault.InvalidRequired.selector);
        new MultiSigVault(owners, 3);
    }

    function test_RevertWhen_OwnerIsZeroAddress() public {
        address[] memory owners = new address[](2);
        owners[0] = alice;
        owners[1] = address(0);
        vm.expectRevert(MultiSigVault.InvalidOwner.selector);
        new MultiSigVault(owners, 1);
    }

    function test_RevertWhen_DuplicateOwner() public {
        address[] memory owners = new address[](2);
        owners[0] = alice;
        owners[1] = alice;
        vm.expectRevert(MultiSigVault.DuplicateOwner.selector);
        new MultiSigVault(owners, 1);
    }

    // ---------- receiving funds ----------

    function test_VaultAcceptsPlainTransfers() public {
        vm.deal(stranger, 5 ether);

        vm.expectEmit(true, false, false, true);
        emit FundsReceived(stranger, 5 ether);

        vm.prank(stranger);
        (bool ok,) = address(vault).call{value: 5 ether}("");

        assertTrue(ok);
        assertEq(vault.vaultBalance(), FUNDING + 5 ether);
    }

    // ---------- submit ----------

    function test_OwnerCanSubmit() public {
        uint256 txId = _submitPayment();

        assertEq(txId, 0);
        assertEq(vault.transactionCount(), 1);

        (address to, uint256 value, bool executed, uint256 approvalCount) = vault.transactions(0);
        assertEq(to, payee);
        assertEq(value, PAYMENT);
        assertFalse(executed);
        assertEq(approvalCount, 0);
    }

    function test_RevertWhen_StrangerSubmits() public {
        vm.prank(stranger);
        vm.expectRevert(MultiSigVault.NotOwner.selector);
        vault.submit(payee, PAYMENT);
    }

    function test_RevertWhen_SubmittingToZeroAddress() public {
        vm.prank(alice);
        vm.expectRevert(MultiSigVault.InvalidOwner.selector);
        vault.submit(address(0), PAYMENT);
    }

    // ---------- approve ----------

    function test_ApprovalIsRecorded() public {
        uint256 txId = _submitPayment();

        vm.prank(alice);
        vault.approve(txId);

        assertTrue(vault.approvedBy(txId, alice));
        assertFalse(vault.approvedBy(txId, bob));

        (,,, uint256 approvalCount) = vault.transactions(txId);
        assertEq(approvalCount, 1);
    }

    function test_RevertWhen_StrangerApproves() public {
        uint256 txId = _submitPayment();

        vm.prank(stranger);
        vm.expectRevert(MultiSigVault.NotOwner.selector);
        vault.approve(txId);
    }

    function test_RevertWhen_ApprovingNonexistentTx() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MultiSigVault.TxDoesNotExist.selector, uint256(99)));
        vault.approve(99);
    }

    function test_RevertWhen_ApprovingTwice() public {
        uint256 txId = _submitPayment();

        vm.startPrank(alice);
        vault.approve(txId);

        vm.expectRevert(abi.encodeWithSelector(MultiSigVault.AlreadyApproved.selector, txId));
        vault.approve(txId);
        vm.stopPrank();
    }

    // ---------- revoke ----------

    function test_OwnerCanRevokeApproval() public {
        uint256 txId = _submitPayment();

        vm.startPrank(alice);
        vault.approve(txId);
        vault.revoke(txId);
        vm.stopPrank();

        assertFalse(vault.approvedBy(txId, alice));

        (,,, uint256 approvalCount) = vault.transactions(txId);
        assertEq(approvalCount, 0);
    }

    function test_RevertWhen_RevokingWithoutApproval() public {
        uint256 txId = _submitPayment();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MultiSigVault.NotApproved.selector, txId));
        vault.revoke(txId);
    }

    function test_RevokeCanBlockExecution() public {
        uint256 txId = _submitPayment();

        vm.prank(alice);
        vault.approve(txId);
        vm.prank(bob);
        vault.approve(txId);

        // bob changes his mind before anyone executed
        vm.prank(bob);
        vault.revoke(txId);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MultiSigVault.NotEnoughApprovals.selector, uint256(1), REQUIRED));
        vault.execute(txId);
    }

    // ---------- execute ----------

    function test_ExecuteSendsFundsWhenThresholdMet() public {
        uint256 txId = _submitPayment();

        vm.prank(alice);
        vault.approve(txId);
        vm.prank(bob);
        vault.approve(txId);

        vm.prank(alice);
        vault.execute(txId);

        assertEq(payee.balance, PAYMENT);
        assertEq(vault.vaultBalance(), FUNDING - PAYMENT);

        (,, bool executed,) = vault.transactions(txId);
        assertTrue(executed);
    }

    /// THE core guarantee: one owner alone cannot move funds.
    function test_RevertWhen_SingleOwnerTriesToExecute() public {
        uint256 txId = _submitPayment();

        vm.startPrank(alice);
        vault.approve(txId);

        vm.expectRevert(abi.encodeWithSelector(MultiSigVault.NotEnoughApprovals.selector, uint256(1), REQUIRED));
        vault.execute(txId);
        vm.stopPrank();

        assertEq(payee.balance, 0);
        assertEq(vault.vaultBalance(), FUNDING);
    }

    function test_RevertWhen_NoApprovalsAtAll() public {
        uint256 txId = _submitPayment();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MultiSigVault.NotEnoughApprovals.selector, uint256(0), REQUIRED));
        vault.execute(txId);
    }

    function test_RevertWhen_StrangerExecutes() public {
        uint256 txId = _submitPayment();

        vm.prank(alice);
        vault.approve(txId);
        vm.prank(bob);
        vault.approve(txId);

        vm.prank(stranger);
        vm.expectRevert(MultiSigVault.NotOwner.selector);
        vault.execute(txId);
    }

    function test_RevertWhen_ExecutingTwice() public {
        uint256 txId = _submitPayment();

        vm.prank(alice);
        vault.approve(txId);
        vm.prank(bob);
        vault.approve(txId);

        vm.startPrank(alice);
        vault.execute(txId);

        vm.expectRevert(abi.encodeWithSelector(MultiSigVault.AlreadyExecuted.selector, txId));
        vault.execute(txId);
        vm.stopPrank();
    }

    function test_RevertWhen_VaultCannotCoverPayment() public {
        vm.prank(alice);
        uint256 txId = vault.submit(payee, 100 ether); // more than the vault holds

        vm.prank(alice);
        vault.approve(txId);
        vm.prank(bob);
        vault.approve(txId);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MultiSigVault.InsufficientBalance.selector, FUNDING, uint256(100 ether)));
        vault.execute(txId);
    }

    function test_RevertWhen_ApprovingAfterExecution() public {
        uint256 txId = _submitPayment();

        vm.prank(alice);
        vault.approve(txId);
        vm.prank(bob);
        vault.approve(txId);
        vm.prank(alice);
        vault.execute(txId);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(MultiSigVault.AlreadyExecuted.selector, txId));
        vault.approve(txId);
    }

    // ---------- full flow ----------

    function test_TwoIndependentTransactions() public {
        vm.prank(alice);
        uint256 tx1 = vault.submit(payee, 1 ether);
        vm.prank(bob);
        uint256 tx2 = vault.submit(stranger, 2 ether);

        // approve and execute only the first
        vm.prank(alice);
        vault.approve(tx1);
        vm.prank(carol);
        vault.approve(tx1);
        vm.prank(bob);
        vault.execute(tx1);

        assertEq(payee.balance, 1 ether);
        assertEq(stranger.balance, 0);

        (,, bool executed1,) = vault.transactions(tx1);
        (,, bool executed2,) = vault.transactions(tx2);
        assertTrue(executed1);
        assertFalse(executed2);
    }
}
