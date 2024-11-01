// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {RenftMarket} from "../src/RenftMarket.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {S2NFT} from "contracts/src/NFTFactory.sol";

contract RenftMarketTest is Test {
    RenftMarket public market;
    address public marketAddr;

    NFTFactory nftFactory;

    IERC721 public nft1;
    address nft1Addr = address(nft1);
    IERC721 public nft2;
    address nft2Addr = address(nft2);

    address maker = address(0x04855890416eba63cACB213f860e5D70Ab3F6870);
    address taker = address(0x04855890416eba63cACB213f860e5D70Ab3F6870);

    function setUp() public {
        market = new RenftMarket();
        marketAddr = address(market);

        nftFactory = new NFTFactory();

        nft = nftFactory.deployNFT;
    }

    function test_Increment() public {
        
        deal(alice, 1000 ether);

        counter.increment();
        counter.increment();
        counter.increment();
        counter.increment();

        vm.stopPrank();
        assertEq(counter.number(), 1);
    }
}
