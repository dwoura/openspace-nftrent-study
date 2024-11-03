// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.25;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {console} from "forge-std/Test.sol";
/**
 * @title RenftMarket
 * @dev NFT租赁市场合约
 *   TODO:
 *      1. 退还NFT：租户在租赁期内，可以随时退还NFT，根据租赁时长计算租金，剩余租金将会退还给出租人
 *      2. 过期订单处理：
 *      3. 领取租金：出租人可以随时领取租金
 */
contract RenftMarket is EIP712 {
   struct RentoutOrder {
      address maker; // 出租方地址
      address nft_ca; // NFT合约地址
      uint256 token_id; // NFT tokenId
      uint256 daily_rent; // 每日租金
      uint256 max_rental_duration; // 最大租赁时长
      uint256 min_collateral; // 最小抵押
      uint256 list_endtime; // 挂单结束时间
   }

   // 租赁信息 
   struct BorrowOrder {
      address taker; // 租方人地址
      uint256 collateral; // 抵押
      uint256 start_time; // 租赁开始时间，方便计算利息
      RentoutOrder rentinfo; // 租赁订单
   }

   uint256 precision = 10e10;

   mapping(bytes32 => BorrowOrder) public orders; // 已租赁订单 rOrder->bOrder
   mapping(bytes32 => bool) public canceledOrders; // 已取消的挂单

   mapping(bytes32 => uint256) lastWithrawTime; // 上次取租金的时间

   bytes32 public constant RENTOUT_ORDER_TYPE_HASH = keccak256("RentoutOrder(address maker,address nft_ca,uint256 token_id,uint256 daily_rent,uint256 max_rental_duration,uint256 min_collateral,uint256 list_endtime)");

   // 出租订单事件
   event BorrowNFT(address indexed taker, address indexed maker, bytes32 orderHash, uint256 collateral);
   // 取消订单事件
   event OrderCanceled(address indexed maker, bytes32 orderHash);
   // 归还事件
   event ReturnNft(bytes32 indexed orderHash, address indexed taker);
   // 提款事件
   event RentWithdrawn(bytes32 indexed orderHash,address indexed maker, uint256 amount); 
   // 清算事件
   event Liquidation(bytes32 indexed orderHash, address indexed taker, uint256 collateral);
   constructor() EIP712("RenftMarket", "1") {}

   function verifySignature(bytes32 hash, bytes memory signature) public pure returns (address) {
      return ECDSA.recover(hash, signature);
   }

   /**
   * @notice 租赁NFT
   * @dev 验证签名后，将NFT从出租人转移到租户，并存储订单信息
   */
   function borrow(RentoutOrder calldata order, bytes calldata makerSignature) external payable {
      require(block.timestamp < order.list_endtime, "order expired");
      require(msg.value >= order.min_collateral, "value eth not enough");

      bytes32 digest = orderHash(order);
      require(canceledOrders[digest] == false,"order has been canceled");
      address signer = verifySignature(digest, makerSignature);
      
      // to verify signature and the rent-out order message, which is actually be published by lesser 
      require(order.maker == signer,"wrong signature");

      // transfer nft from maker to taker
      IERC721 nft = IERC721(order.nft_ca);
      require(address(this) == nft.getApproved(order.token_id), "nft not be approved for market");
      nft.safeTransferFrom(order.maker, msg.sender, order.token_id);

      // update info
      orders[digest] = BorrowOrder({
         taker: msg.sender,
         collateral: msg.value,
         start_time: block.timestamp,
         rentinfo: order
      });
      lastWithrawTime[digest] = block.timestamp;

      // emit event
      emit BorrowNFT(msg.sender, order.maker, digest, order.min_collateral);
   }

   /**
   * 1. 取消时一定要将取消的信息在链上标记，防止订单被使用！
   * 2. 防DOS： 取消订单有成本，这样防止随意的挂单，
   */
   function cancelOrder(RentoutOrder calldata order, bytes calldata makerSignature) external {
      bytes32 digest = orderHash(order);
      address signer = verifySignature(digest, makerSignature);

      require(msg.sender == signer, "only signer can cancel the order");
      require(!canceledOrders[digest], "order has been canceled");

      canceledOrders[digest] = true;

      emit OrderCanceled(order.maker, digest);
   }

   // 计算订单哈希
   function orderHash(RentoutOrder memory order) public view returns (bytes32) {
      // RentoutOrder digest
      bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(
            RENTOUT_ORDER_TYPE_HASH,
            order.maker,
            order.nft_ca,
            order.token_id,
            order.daily_rent,
            order.max_rental_duration,
            order.min_collateral,
            order.list_endtime
      )));
      return digest;
   }

   function computeRent(bytes32 rOrderHash) public view returns(bool,uint256){
      BorrowOrder memory bOrder = orders[rOrderHash];
      uint256 lastWithdrawTime =  lastWithrawTime[rOrderHash];
      uint256 startTime = bOrder.start_time;
      uint256 maxDuration = bOrder.rentinfo.max_rental_duration;
      uint256 rentPerSecond = Math.ceilDiv(bOrder.rentinfo.daily_rent * precision, 1 days); // 每秒租金 todo: 直接整除有精度问题！！

      uint256 rentedSecond = block.timestamp - lastWithdrawTime;// 未收取租金的时间段
      uint256 realizedRent =  (lastWithdrawTime - startTime) * rentPerSecond;
      uint256 rent = rentedSecond * rentPerSecond / precision; // 精度处理
      if( block.timestamp > (startTime + maxDuration) || (rent + realizedRent) > bOrder.collateral ){
         // return max rent when overdue or over the rent
         bool isLiquidate = true;
         return (isLiquidate, bOrder.collateral); // max rent is collateral
      }

      return (false,rent);
   }

   function liquidateNft(BorrowOrder memory bOrder) internal{
      // 清算抵押物，抵押物
      payable(bOrder.rentinfo.maker).transfer(bOrder.collateral);

      bytes32 digest = orderHash(bOrder.rentinfo);

      emit Liquidation(digest, bOrder.taker, bOrder.collateral);
   }

   // return nft by taker
   function returnNft(bytes32 rOrderHash) public {
      BorrowOrder memory bOrder = orders[rOrderHash];
      require(bOrder.taker != address(0), "order not exist");
      require(msg.sender == bOrder.taker, "only taker of nft can return");

      // check rent value and collateral value
      (bool isLiquidate,uint rent) = computeRent(rOrderHash);
      if(isLiquidate == true){
         // liquidate
         liquidateNft(bOrder);
         return;
      }

      // 1. return rent and nft to maker
      payable(bOrder.rentinfo.maker).transfer(rent);

      IERC721 nft = IERC721(bOrder.rentinfo.nft_ca);
      require(address(this) == nft.getApproved(bOrder.rentinfo.token_id), "market needs to be approved");
      nft.safeTransferFrom(msg.sender, bOrder.rentinfo.maker, bOrder.rentinfo.token_id);

      // 2. return remaining collateral to taker
      uint256 rentPerSecond = bOrder.rentinfo.daily_rent / 1 days;
      uint refund = bOrder.collateral - (block.timestamp - bOrder.start_time ) * rentPerSecond;
      // send refund
      payable(msg.sender).transfer(refund);

      // remove the order
      delete orders[rOrderHash];

      emit ReturnNft(rOrderHash,msg.sender);
   }

   // rent withdraw
   function rentWithdraw(bytes32 rOrderHash) public returns(uint256){
      BorrowOrder storage bOrder = orders[rOrderHash];
      require(bOrder.taker != address(0), "order not exist");
      require(msg.sender == bOrder.rentinfo.maker, "only order maker can do this");
      
      // check rent value and collateral value
      (bool isLiquidate,uint rent) = computeRent(rOrderHash);
      if(isLiquidate == true){
         // liquidate
         liquidateNft(bOrder);
         return 0;
      }

      payable(msg.sender).transfer(rent);

      // update last withdraw time
      lastWithrawTime[rOrderHash] = block.timestamp;

      emit RentWithdrawn(rOrderHash,msg.sender, rent);
      return rent;
   }

   function hashTypedDataV4(bytes32 structHash) public view returns(bytes32 digest){
      digest = _hashTypedDataV4(structHash);
   }

   function Rentout_Order_Type_Hash() public pure returns(bytes32){
      return RENTOUT_ORDER_TYPE_HASH;
   }

   function getOrders(bytes32 rOrderHash) public view returns(BorrowOrder memory){
      return orders[rOrderHash];
   }

}
