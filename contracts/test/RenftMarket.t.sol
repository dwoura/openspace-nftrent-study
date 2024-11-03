// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {RenftMarket} from "../src/RenftMarket.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {NFTFactory,S2NFT} from "src/NFTFactory.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

contract RenftMarketTest is Test {
    RenftMarket public market;
    address public marketAddr;

    NFTFactory nftFactory;

    address nftAddr;
    S2NFT public nft;

    address maker;
    uint makerPvkey;
    address taker;
    uint takerPvkey;

    function setUp() public {
        market = new RenftMarket();
        marketAddr = address(market);

        nftFactory = new NFTFactory();
        nftAddr = nftFactory.deployNFT("Dwoura'sNft","DwNFT","ipfs://xx",1000);
        nft = S2NFT(nftAddr);

        makerPvkey = uint256(0x93b78322fb0423726afdffa101bfee6a117d57ccb7bfb0672693d864b6201624);
        maker = vm.addr(makerPvkey);
        (taker, takerPvkey) = makeAddrAndKey("taker");

        vm.deal(maker,10 ether);
        vm.deal(taker,10 ether);
        //vm.deal(marketAddr,0.001 ether);

        // nfts minted by maker
        vm.prank(maker);
        nft.freeMint(5);
    }

    // test situations
    // 1.   listing order overdue, not be purchased
    // 2.   borrow success
    // 3.1  return or withdraw (success: execute liquidation)
    //      blocktimestamp < start time + duration
    // 3.2  return or withdraw (fail: execute liquidation)
    //      blocktimestamp > start time + duration   just need to setup block time stamp near (start time + duration)
    // 3.3  return or withdraw (fail: execute liquidation)
    // 4    cancelOrder

    // generate a offline list order signature
    function generateRentoutOrderSignature(RenftMarket.RentoutOrder memory order) internal view returns(bytes memory signature){
        //bytes32 hashTypedData =  market._hashTypedDataV4(structHash); // 先从结果出发，找到需要的使用的参数和工具，开发思路会更清晰
        bytes32 digest = market.hashTypedDataV4(keccak256(abi.encode(
            market.RENTOUT_ORDER_TYPE_HASH(),
            order.maker,
            order.nft_ca,
            order.token_id, // token_id
            order.daily_rent,
            order.max_rental_duration,
            order.min_collateral,
            order.list_endtime
        )));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPvkey, digest);

        signature = abi.encodePacked(r,s,v);
    }

    uint256 TOKEN_ID = 1;
    uint256 DAILY_RENT = 0.1 ether;
    uint256 MAX_DURATION = 1 weeks;
    uint256 MIN_COLLATERAL = 1 ether;
    uint256 LIST_ENDTIME = block.timestamp + 1 days;
    function makeRentoutOrder() internal view returns(RenftMarket.RentoutOrder memory){
        uint256 dailyRent = DAILY_RENT;
        uint256 maxDuration = MAX_DURATION;
        uint256 minCollateral = MIN_COLLATERAL;
        uint256 listEndtime = LIST_ENDTIME;
        uint256 tokenId = TOKEN_ID;
        // when testing, you can use vm.warp to set block timestamp + 2 days;
        
        RenftMarket.RentoutOrder memory rentoutOrder = RenftMarket.RentoutOrder(
            maker,
            nftAddr,
            tokenId, // tokenid
            dailyRent, // 1 eth 1 day
            maxDuration, // max duration 2days
            minCollateral, // min collateral eth
            listEndtime
        );

        return rentoutOrder;
    }

    // situation 1
    function test_Borrow_RentoutOrder_Overdue() public {
        (
            RenftMarket.RentoutOrder memory rOrder,
            bytes memory makerSig
        ) = doMakerApproveAndSignOrder();

        // borrow when timestamp exceeds listEndtime of rOrder
        vm.warp(block.timestamp + 2 days);
        // expect revert
        vm.expectRevert("order expired");
        vm.prank(taker);
        market.borrow(rOrder, makerSig);
    }

    function test_Borrow_RentoutOrder_Success() public {
        (
            RenftMarket.RentoutOrder memory rOrder,
            bytes memory makerSig
        ) = doMakerApproveAndSignOrder();

        // borrow when timestamp not exceeds listEndtime of rOrder
        vm.warp(block.timestamp);
        // expect revert
        vm.expectEmit(true, true, false,true);
        emit RenftMarket.BorrowNFT(taker, rOrder.maker, market.orderHash(rOrder), rOrder.min_collateral);
        
        vm.prank(taker);
        market.borrow{value: rOrder.min_collateral}(rOrder, makerSig); // send eth

        assertEq(nft.ownerOf(TOKEN_ID), taker);
    }

    function doMakerApproveAndSignOrder() internal returns(RenftMarket.RentoutOrder memory, bytes memory){
        // approve nft
        vm.prank(maker);
        nft.approve(marketAddr, TOKEN_ID);

        // cook order
        RenftMarket.RentoutOrder memory rOrder = makeRentoutOrder();
        bytes memory makerSig = generateRentoutOrderSignature(rOrder);

        return (rOrder,makerSig);
    }

    function test_Borrow_RentoutOrder_Failed() public {
        (
            RenftMarket.RentoutOrder memory rOrder,
            bytes memory makerSig
        ) = doMakerApproveAndSignOrder();

        // expect revert
        vm.startPrank(taker);
        uint256 timestampBefore = block.timestamp;
        vm.expectRevert("value eth not enough");
        market.borrow(rOrder, makerSig);

        vm.expectRevert("order expired");
        vm.warp(rOrder.list_endtime);
        market.borrow{value: rOrder.min_collateral}(rOrder, makerSig);

        vm.warp(timestampBefore);
        vm.expectRevert("only signer can cancel the order");
        market.cancelOrder(rOrder, makerSig);
        market.borrow{value: rOrder.min_collateral}(rOrder, makerSig);
        vm.stopPrank();

        vm.prank(maker);
        market.cancelOrder(rOrder, makerSig);
        vm.expectRevert("order has been canceled"); // 只是 expect 下一个 call
        vm.prank(taker);
        market.borrow{value: rOrder.min_collateral}(rOrder, makerSig);

    }

    function test_CancelOrder() public {
        (
            RenftMarket.RentoutOrder memory rOrder,
            bytes memory makerSig
        ) = doMakerApproveAndSignOrder();

        // cancel order       
        bytes32 digest = market.orderHash(rOrder);
        vm.expectEmit(true, false, false,true);
        emit RenftMarket.OrderCanceled(rOrder.maker, digest);
        vm.prank(maker);
        market.cancelOrder(rOrder, makerSig);

        assertEq(market.canceledOrders(digest), true);
    }

    function test_ReturnNft_Success() public {
        (
            RenftMarket.RentoutOrder memory rOrder,
            bytes memory makerSig
        ) = doMakerApproveAndSignOrder();

        // taker borrow
        vm.prank(taker);
        market.borrow{value: rOrder.min_collateral}(rOrder, makerSig); // send eth

        // taker return
        vm.prank(taker);
        nft.approve(marketAddr, TOKEN_ID); // approve market firstly
        bytes32 digest = market.orderHash(rOrder);
        vm.expectEmit(true, false, false,true);
        emit RenftMarket.ReturnNft(digest,taker);
        vm.prank(taker);
        market.returnNft(digest);

        assertEq(nft.ownerOf(TOKEN_ID), maker);
    }

    function test_ReturnNft_Liquidation() public {
        (
            RenftMarket.RentoutOrder memory rOrder,
            bytes memory makerSig
        ) = doMakerApproveAndSignOrder();

        
        uint256 makerEthBefore = maker.balance;

        // taker borrow
        vm.prank(taker);
        market.borrow{value: rOrder.min_collateral}(rOrder, makerSig); // send eth

        uint256 marketEthBefore = marketAddr.balance;

        // overtime borrow and return
        bytes32 digest = market.orderHash(rOrder);
        RenftMarket.BorrowOrder memory bOrder = market.getOrders(digest);
        

        // expect and assert
        uint256 startTime = block.timestamp;
        vm.warp(startTime + rOrder.max_rental_duration + 1);
        vm.prank(taker);
        nft.approve(marketAddr, TOKEN_ID); // approve market firstly≤

        vm.expectEmit(true, false, false,true);
        emit RenftMarket.Liquidation(digest, bOrder.taker, bOrder.collateral);
        vm.prank(taker); // only taker can return 
        market.returnNft(digest);

        

        uint256 marketEthAfter = marketAddr.balance;
        uint256 makerEthAfter = maker.balance;

        assertEq(marketEthAfter, marketEthBefore - bOrder.collateral);
        assertEq(makerEthAfter, makerEthBefore + bOrder.collateral);
    }

    function test_RentWithdraw_Success() public {
        (
            RenftMarket.RentoutOrder memory rOrder,
            bytes memory makerSig
        ) = doMakerApproveAndSignOrder();
        bytes32 digest = market.orderHash(rOrder);
        
        uint256 makerEthBefore = maker.balance;

        // taker borrow
        vm.prank(taker);
        market.borrow{value: rOrder.min_collateral}(rOrder, makerSig); // send eth

        // warp time and maker withdraw rent
        vm.warp(block.timestamp + 2 days); // assume lasted 2 days
        vm.expectEmit(true, false, false,true);
        emit RenftMarket.RentWithdrawn(digest, rOrder.maker, DAILY_RENT * 2);
        vm.prank(maker);
        uint256 rent = market.rentWithdraw(digest);

        uint256 makerEthAfter = maker.balance;
        assertEq(makerEthAfter, makerEthBefore + rent);

    }
}
