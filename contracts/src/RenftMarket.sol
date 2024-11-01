// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.25;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

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

   //mapping(uint256 => BorrowOrder) public orders; // id->border 已租赁订单
   mapping(bytes32 => BorrowOrder) public orders; // 已租赁订单
   mapping(bytes32 => bool) public canceledOrders; // 已取消的挂单

   // mapping(address=>uint) collaterals; // nums of collateralized eth
   uint8 COLLATERAL_LIQUIDATION = -1;

   bytes32 public constant RENTOUT_ORDER_TYPE_HASH = keccak256("RentoutOrder(address maker,address nft_ca,uint256 token_id,uint256 daily_rent,uint256 max_rental_duration,uint256 min_collateral,uint256 list_endtime)");

   // 出租订单事件
   event BorrowNFT(address indexed taker, address indexed maker, bytes32 orderHash, uint256 collateral);
   // 取消订单事件
   event OrderCanceled(address indexed maker, bytes32 orderHash);
   // 归还事件
   event ReturnNft(address indexed taker, bytes32 orderHash);
   // 提款事件
   event RentWithdrawn(address indexed maker, uint256 amount); 
   // 清算事件
   event Liquidation(bytes32 indexed orderHash, address taker, uint256 collateral);
   constructor() EIP712("RenftMarket", "1") {}

   /**
   * @notice 租赁NFT
   * @dev 验证签名后，将NFT从出租人转移到租户，并存储订单信息
   */
   function borrow(RentoutOrder calldata order, bytes calldata makerSignature) external payable {
      require( block.timestamp < order.list_endtime, "order expired");
      require(msg.value >= order.min_collateral, "eth balance not enough");

      bytes32 digest = orderHash(order);
      address recoveredAddr = ECDSA.recover(digest, signature);
      
      // to verify signature and the rent-out order message, which is actually be published by lesser 
      require(order.maker == recoveredAddr);

      // transfer nft from lesser to lessee
      IERC721 nft = IERC721(order.nft_ca);
      require(address(this) == nft.getApproved(tokenId), "nft not be approve for market");
      nft.safeTransferFrom(order.maker, msg.sender, tokenId);

      // update info
      //collaterals[msg.sender] = msg.value;
      orders[digest] = BorrowOrder({
         taker: msg.sender,
         collateral: msg.value,
         start_time: block.timestamp,
         rentinfo: order
      });
      lastWithdrawTime[digest] = block.timestamp; // 更新maker计算租金的起始时间

      // emit event
      emit BorrowNFT(msg.sender, order.maker, digest, order.min_collateral);
   }

   /**
   * 1. 取消时一定要将取消的信息在链上标记，防止订单被使用！
   * 2. 防DOS： 取消订单有成本，这样防止随意的挂单，
   */
   function cancelOrder(RentoutOrder calldata order, bytes calldata makerSignatre) external {
      bytes digest = orderHash(order);
      address signer = ECDSA.recover(digest, makerSignature);
      require(msg.sender == signer, "only signer can cancel the order");
      
      require(!canceledOrders[digest], "order has been canceled");

      canceledOrders[digest] = true;

      emit OrderCanceled(order.maker, orderHash);
   }

   // 计算订单哈希
   function orderHash(RentoutOrder calldata order) public view returns (bytes32) {
      // RentoutOrder digest
      bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(
         RENT_OUT_ORDER_TYPE_HASH,
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

   function computeRent(BorrowOrder bOrder) public view returns(uint256 rent){
      uint256 startTime = bOrder.start_time;
      uint256 maxDuration = bOrder.rentinfo.max_rental_duration;
      uint256 rentPerSecond = bOrder.rentinfo.daily_rent / 1 days; // 每秒租金

      if(block.timestamp - bOrder.start_time > bOrder.rentinfo.max_rental_duration){
         // return max rent when overdue
         return COLLATERAL_LIQUIDATION;
      }

      uint256 rentedSecond = block.timestamp - startTime;// 未收取租金的时间段
      rent = rentedSecond * rentPerSecond;
   }

   function liquidateNft(BorrowOrder bOrder) internal{
      // 清算抵押物，抵押物
      payable(bOrder.rentinfo.maker).transfer(bOrder.collateral);

      emit Liquidation(borrowOrderHash, bOrder.taker, bOrder.collateral);
   }

   // return nft by taker
   function returnNft(bytes32 borrowOrderHash) public {
      BorrowOrder bOrder = orders[borrowOrderHash];
      require(bOrder, "order not exist");
      require(msg.sender == bOrder.taker, "only taker of nft can return");

      // check rent value and collateral value
      uint rent = computeRent(bOrder);
      if(rent == COLLATERAL_LIQUIDATION){
         // liquidate
         liquidate(bOrder);
         return;
      }

      // 1. return rent and nft to maker
      payable(bOrder.rentinfo.maker).transfer(rent);

      IERC721 nft = IERC721(bOrder.rentinfo.nft_ca);
      require(address(this) == nft.getApproved(bOrder.rentinfo.token_id), "market not be approved");
      nft.safeTransferFrom(msg.sender, bOrder.rentinfo.maker, tokenId);

      // 2. return remaining collateral
      uint256 rentPerSecond = bOrder.rentinfo.daily_rent / 1 days;
      uint refund = bOrder.rentinfo.max_rental_duration * rentPerSecond;
      // send refund
      payable(msg.sender).transfer(refund);

      // remove the order
      delete orders[borrowOrderHash];

      emit ReturnNft(msg.sender, borrowOrderHash);
   }

   // rent withdraw
   function rentWithdraw(bytes32 borrowOrderHash) public {
      BorrowOrder bOrder = orders[borrowOrderHash];
      require(bOrder, "order not exist");
      require(msg.sender == bOrder.rentinfo.maker, "only order maker can do this");
      
      // check rent value and collateral value
      uint rent = computeRent(bOrder);
      if(rent == COLLATERAL_LIQUIDATION){
         // liquidate
         liquidate(bOrder);
         return;
      }

      payable(msg.sender).transfer(rent);

      // update maxDuration and rent startTime
      // startTime↑, maxDuration↓, the sum is constant
      bOrder.rentinfo.max_rental_duration -= block.timestamp - bOrder.start_time;
      bOrder.start_time = block.timestamp;

      emit RentWithdrawn(msg.sender, rent);
   }

}
