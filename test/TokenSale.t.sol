// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TokenSale} from "../src/TokenSale.sol";
import {MyToken} from "../src/MyToken.sol";

contract TokenSaleTest is Test {
    MyToken token;
    TokenSale sale;

    address owner = makeAddr("owner");
    address buyer = makeAddr("buyer");
    address buyer2 = makeAddr("buyer2");
    address stranger = makeAddr("stranger");

    uint256 constant RATE = 1000; // 1000 MTK per 1 ETH
    uint256 constant DURATION = 7 days;
    uint256 constant SALE_SUPPLY = 500_000 ether; // 500k tokens (18 decimals)

    event TokensPurchased(address indexed buyer, uint256 ethPaid, uint256 tokensReceived);
    event ProceedsWithdrawn(address indexed to, uint256 amount);
    event UnsoldTokensRecovered(address indexed to, uint256 amount);

    function setUp() public {
        vm.startPrank(owner);
        token = new MyToken();
        sale = new TokenSale(address(token), RATE, DURATION);
        require(token.transfer(address(sale), SALE_SUPPLY), "setup transfer failed");
        vm.stopPrank();

        vm.deal(buyer, 100 ether);
        vm.deal(buyer2, 100 ether);
    }

    // ---------- deployment ----------

    function test_InitialState() public view {
        assertEq(address(sale.token()), address(token));
        assertEq(sale.rate(), RATE);
        assertEq(sale.owner(), owner);
        assertEq(sale.saleEnd(), block.timestamp + DURATION);
        assertEq(sale.tokensRemaining(), SALE_SUPPLY);
        assertEq(sale.totalRaised(), 0);
        assertTrue(sale.saleActive());
    }

    function test_RevertWhen_TokenIsZeroAddress() public {
        vm.expectRevert(TokenSale.InvalidAddress.selector);
        new TokenSale(address(0), RATE, DURATION);
    }

    function test_RevertWhen_RateIsZero() public {
        vm.expectRevert(TokenSale.InvalidRate.selector);
        new TokenSale(address(token), 0, DURATION);
    }

    function test_RevertWhen_DurationIsZero() public {
        vm.expectRevert(TokenSale.InvalidDuration.selector);
        new TokenSale(address(token), RATE, 0);
    }

    // ---------- buying ----------

    function test_BuyTransfersTokensAndRecordsContribution() public {
        vm.prank(buyer);
        sale.buy{value: 1 ether}();

        assertEq(token.balanceOf(buyer), 1000 ether); // 1 ETH * rate
        assertEq(sale.tokensRemaining(), SALE_SUPPLY - 1000 ether);
        assertEq(sale.contributions(buyer), 1 ether);
        assertEq(sale.totalRaised(), 1 ether);
        assertEq(address(sale).balance, 1 ether);
    }

    function test_BuyEmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit TokensPurchased(buyer, 2 ether, 2000 ether);

        vm.prank(buyer);
        sale.buy{value: 2 ether}();
    }

    function test_MultipleBuysAccumulate() public {
        vm.prank(buyer);
        sale.buy{value: 1 ether}();
        vm.prank(buyer);
        sale.buy{value: 3 ether}();

        assertEq(sale.contributions(buyer), 4 ether);
        assertEq(token.balanceOf(buyer), 4000 ether);
    }

    function test_SeparateBuyersTrackedIndependently() public {
        vm.prank(buyer);
        sale.buy{value: 1 ether}();
        vm.prank(buyer2);
        sale.buy{value: 5 ether}();

        assertEq(sale.contributions(buyer), 1 ether);
        assertEq(sale.contributions(buyer2), 5 ether);
        assertEq(sale.totalRaised(), 6 ether);
        assertEq(token.balanceOf(buyer), 1000 ether);
        assertEq(token.balanceOf(buyer2), 5000 ether);
    }

    function test_RevertWhen_BuyingWithZeroEth() public {
        vm.prank(buyer);
        vm.expectRevert(TokenSale.NoEthSent.selector);
        sale.buy{value: 0}();
    }

    function test_RevertWhen_BuyingAfterSaleEnds() public {
        vm.warp(block.timestamp + DURATION);

        vm.prank(buyer);
        vm.expectRevert(TokenSale.SaleEnded.selector);
        sale.buy{value: 1 ether}();
    }

    function test_RevertWhen_RequestingMoreTokensThanAvailable() public {
        vm.deal(buyer, 600 ether);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(TokenSale.NotEnoughTokensLeft.selector, uint256(501_000 ether), SALE_SUPPLY)
        );
        sale.buy{value: 501 ether}();
    }

    function test_CanBuyExactlyAllRemainingTokens() public {
        vm.deal(buyer, 600 ether);

        vm.prank(buyer);
        sale.buy{value: 500 ether}();

        assertEq(token.balanceOf(buyer), SALE_SUPPLY);
        assertEq(sale.tokensRemaining(), 0);
    }

    // ---------- proceeds ----------

    function test_OwnerCanWithdrawProceeds() public {
        vm.prank(buyer);
        sale.buy{value: 4 ether}();

        uint256 ownerBefore = owner.balance;

        vm.prank(owner);
        sale.withdrawProceeds();

        assertEq(owner.balance, ownerBefore + 4 ether);
        assertEq(address(sale).balance, 0);
    }

    function test_RevertWhen_StrangerWithdrawsProceeds() public {
        vm.prank(buyer);
        sale.buy{value: 1 ether}();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        sale.withdrawProceeds();
    }

    function test_RevertWhen_WithdrawingWithNoProceeds() public {
        vm.prank(owner);
        vm.expectRevert(TokenSale.NothingToWithdraw.selector);
        sale.withdrawProceeds();
    }

    // ---------- unsold tokens ----------

    function test_OwnerCanRecoverUnsoldTokensAfterSale() public {
        vm.prank(buyer);
        sale.buy{value: 10 ether}(); // 10,000 tokens sold

        vm.warp(block.timestamp + DURATION);

        uint256 ownerBefore = token.balanceOf(owner);

        vm.prank(owner);
        sale.recoverUnsoldTokens();

        assertEq(token.balanceOf(address(sale)), 0);
        assertEq(token.balanceOf(owner), ownerBefore + (SALE_SUPPLY - 10_000 ether));
    }

    function test_RevertWhen_RecoveringBeforeSaleEnds() public {
        vm.prank(owner);
        vm.expectRevert(TokenSale.SaleNotEnded.selector);
        sale.recoverUnsoldTokens();
    }

    function test_RevertWhen_StrangerRecoversTokens() public {
        vm.warp(block.timestamp + DURATION);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        sale.recoverUnsoldTokens();
    }

    function test_RevertWhen_RecoveringWithNothingLeft() public {
        vm.deal(buyer, 600 ether);
        vm.prank(buyer);
        sale.buy{value: 500 ether}(); // buys everything

        vm.warp(block.timestamp + DURATION);

        vm.prank(owner);
        vm.expectRevert(TokenSale.NothingToWithdraw.selector);
        sale.recoverUnsoldTokens();
    }

    // ---------- views ----------

    function test_SaleActiveFlipsAfterDeadline() public {
        assertTrue(sale.saleActive());
        vm.warp(block.timestamp + DURATION);
        assertFalse(sale.saleActive());
    }
}
