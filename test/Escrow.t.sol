// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Escrow} from "../src/Escrow.sol";

contract EscrowTest is Test {
    Escrow escrow;

    address buyer    = makeAddr("buyer");
    address seller   = makeAddr("seller");
    address arbiter  = makeAddr("arbiter");
    address stranger = makeAddr("stranger");

    uint constant TIMEOUT = 7 days;
    uint constant PRICE   = 1 ether;

    function setUp() public {
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        escrow = new Escrow(seller, arbiter, TIMEOUT);
    }

    // ---------- deployment ----------

    function test_InitialState() public view {
        assertEq(escrow.buyer(), buyer);
        assertEq(escrow.seller(), seller);
        assertEq(escrow.arbiter(), arbiter);
        assertEq(escrow.timeoutPeriod(), TIMEOUT);
        assertEq(uint(escrow.currentState()), uint(Escrow.State.AWAITING_PAYMENT));
    }

    function test_RevertWhen_SellerIsZeroAddress() public {
        vm.expectRevert(Escrow.InvalidAddress.selector);
        new Escrow(address(0), arbiter, TIMEOUT);
    }

    function test_RevertWhen_TimeoutIsZero() public {
        vm.expectRevert(Escrow.InvalidTimeout.selector);
        new Escrow(seller, arbiter, 0);
    }

    // ---------- deposit ----------

    function test_DepositMovesToAwaitingDelivery() public {
        vm.prank(buyer);
        escrow.deposit{value: PRICE}();

        assertEq(uint(escrow.currentState()), uint(Escrow.State.AWAITING_DELIVERY));
        assertEq(escrow.contractBalance(), PRICE);
        assertEq(escrow.deliveryDeadline(), block.timestamp + TIMEOUT);
    }

    function test_RevertWhen_NonBuyerDeposits() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        vm.expectRevert(Escrow.NotBuyer.selector);
        escrow.deposit{value: PRICE}();
    }

    function test_RevertWhen_DepositIsZero() public {
        vm.prank(buyer);
        vm.expectRevert(Escrow.NoFundsSent.selector);
        escrow.deposit{value: 0}();
    }

    function test_RevertWhen_DepositingTwice() public {
        vm.startPrank(buyer);
        escrow.deposit{value: PRICE}();

        vm.expectRevert(
            abi.encodeWithSelector(
                Escrow.InvalidState.selector,
                Escrow.State.AWAITING_PAYMENT,
                Escrow.State.AWAITING_DELIVERY
            )
        );
        escrow.deposit{value: PRICE}();
        vm.stopPrank();
    }

    // ---------- confirmDelivery ----------

    function test_ConfirmDeliveryPaysSeller() public {
        vm.startPrank(buyer);
        escrow.deposit{value: PRICE}();
        escrow.confirmDelivery();
        vm.stopPrank();

        assertEq(seller.balance, PRICE);
        assertEq(escrow.contractBalance(), 0);
        assertEq(uint(escrow.currentState()), uint(Escrow.State.COMPLETE));
    }

    function test_RevertWhen_SellerConfirmsDelivery() public {
        vm.prank(buyer);
        escrow.deposit{value: PRICE}();

        vm.prank(seller);
        vm.expectRevert(Escrow.NotBuyer.selector);
        escrow.confirmDelivery();
    }

    function test_RevertWhen_ConfirmingTwice() public {
        vm.startPrank(buyer);
        escrow.deposit{value: PRICE}();
        escrow.confirmDelivery();

        vm.expectRevert(
            abi.encodeWithSelector(
                Escrow.InvalidState.selector,
                Escrow.State.AWAITING_DELIVERY,
                Escrow.State.COMPLETE
            )
        );
        escrow.confirmDelivery();
        vm.stopPrank();
    }

    // ---------- refundBuyer ----------

    function test_ArbiterCanRefundBuyer() public {
        uint buyerBalanceBefore = buyer.balance;

        vm.prank(buyer);
        escrow.deposit{value: PRICE}();

        vm.prank(arbiter);
        escrow.refundBuyer();

        assertEq(buyer.balance, buyerBalanceBefore);
        assertEq(uint(escrow.currentState()), uint(Escrow.State.REFUNDED));
    }

    function test_RevertWhen_BuyerTriesToRefundSelf() public {
        vm.startPrank(buyer);
        escrow.deposit{value: PRICE}();

        vm.expectRevert(Escrow.NotArbiter.selector);
        escrow.refundBuyer();
        vm.stopPrank();
    }

    // ---------- claimTimeout ----------

    function test_RevertWhen_SellerClaimsBeforeDeadline() public {
        vm.prank(buyer);
        escrow.deposit{value: PRICE}();

        uint deadline = escrow.deliveryDeadline();

        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(Escrow.TooEarly.selector, deadline, block.timestamp)
        );
        escrow.claimTimeout();
    }

    function test_SellerCanClaimAfterDeadline() public {
        vm.prank(buyer);
        escrow.deposit{value: PRICE}();

        vm.warp(block.timestamp + TIMEOUT + 1);

        vm.prank(seller);
        escrow.claimTimeout();

        assertEq(seller.balance, PRICE);
        assertEq(uint(escrow.currentState()), uint(Escrow.State.COMPLETE));
    }

    function test_RevertWhen_StrangerClaimsTimeout() public {
        vm.prank(buyer);
        escrow.deposit{value: PRICE}();

        vm.warp(block.timestamp + TIMEOUT + 1);

        vm.prank(stranger);
        vm.expectRevert(Escrow.NotSeller.selector);
        escrow.claimTimeout();
    }

    // ---------- cancel ----------

    function test_BuyerCanCancelBeforePayment() public {
        vm.prank(buyer);
        escrow.cancel();

        assertEq(uint(escrow.currentState()), uint(Escrow.State.CANCELLED));
    }

    function test_SellerCanCancelBeforePayment() public {
        vm.prank(seller);
        escrow.cancel();

        assertEq(uint(escrow.currentState()), uint(Escrow.State.CANCELLED));
    }

    function test_RevertWhen_StrangerCancels() public {
        vm.prank(stranger);
        vm.expectRevert(Escrow.NotParty.selector);
        escrow.cancel();
    }

    function test_RevertWhen_CancellingAfterDeposit() public {
        vm.startPrank(buyer);
        escrow.deposit{value: PRICE}();

        vm.expectRevert(
            abi.encodeWithSelector(
                Escrow.InvalidState.selector,
                Escrow.State.AWAITING_PAYMENT,
                Escrow.State.AWAITING_DELIVERY
            )
        );
        escrow.cancel();
        vm.stopPrank();
    }

    function test_RevertWhen_DepositingAfterCancel() public {
        vm.startPrank(buyer);
        escrow.cancel();

        vm.expectRevert(
            abi.encodeWithSelector(
                Escrow.InvalidState.selector,
                Escrow.State.AWAITING_PAYMENT,
                Escrow.State.CANCELLED
            )
        );
        escrow.deposit{value: PRICE}();
        vm.stopPrank();
    }
}