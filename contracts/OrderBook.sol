// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./IOrderBook.sol";
import "hardhat/console.sol";

contract OrderBook is ReentrancyGuard, Pausable, Ownable, IOrderBook {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  IERC20 private baseToken;
  uint256 private orderID;
  address private devWallet;

  mapping(address => AssetInfo) private assetInfos;  // asset address => isExist
  mapping(uint256 => AssetListInfo) private assetList;    // index => asset address
  uint256 private assetCnt;

  mapping(uint256 => OrderInfo) private orderInfos;  // orderID => orderInfo
  uint256 private orderCount;

  mapping(address => mapping(uint256 => mapping(uint256 => Order))) private askOrders; // tradeTokenAddress => price => index => Order
  mapping(address => mapping(uint256 => OrderPrice)) private askOrderPrices; // tradeTokenAddress => price => OrderPrice
  mapping(address => mapping(uint256 => uint256)) private askOrderCounts; // tradeTokenAddress => price => count
  mapping(address => uint256) private minSellPrice;  // tradeTokenAddress => minSellPrice
  
  mapping(address => mapping(uint256 => mapping(uint256 => Order))) private bidOrders; // tradeTokenAddress => price => index =>Order
  mapping(address => mapping(uint256 => OrderPrice)) private bidOrderPrices; // tradeTokenAddress => price => OrderPrice
  mapping(address => mapping(uint256 => uint256)) private bidOrderCounts; // tradeTokenAddress => price => count
  mapping(address => uint256) private maxBuyPrice;  // tradeTokenAddress => maxSellPrice

  mapping(uint256 => FeeRule) private takerFees; // index => maxPrice
  mapping(uint256 => FeeRule) private makerFees; // index => maxPrice
  mapping(uint256 => ProfitRule) private splitProfits; // index => maxPrice
  uint256 private takerFeeCnt;
  uint256 private makerFeeCnt;
  uint256 private splitProfitCnt;

  uint8 private ORDER_TYPE_ASK = 0;
  uint8 private ORDER_TYPE_BID = 1;

  uint8 private ORDER_STATUS_OPEN = 0;
  uint8 private ORDER_STATUS_PART_EXECUTED = 1;
  uint8 private ORDER_STATUS_EXECUTED = 2;
  uint8 private ORDER_STATUS_CLOSED = 3;

  /**
   * @notice constructor 
   */
   constructor(address _baseToken, address _devWallet) {
     baseToken = IERC20(_baseToken);
     devWallet = _devWallet;
   }

   function setDevWallet(address _devWallet) external onlyOwner whenNotPaused {
     devWallet = _devWallet;
   }

   function migrateOrder(OrderInfo memory _orderInfo) external nonReentrant whenNotPaused onlyOwner {

     require (_orderInfo.tradeTokenAddress != address(0), "orderbook: tradetoken can't be zero token.");
     require (_orderInfo.tradeTokenAddress != address(baseToken), "orderbook: can't place order with same token.");
     require (_orderInfo.maker != address(0), "orderbook: maker should not be zero address.");
     require (msg.sender != address(0), "orderbook: owner can't be zero address.");
     require (_orderInfo.orderType == 0 || _orderInfo.orderType == 1, "orderbook: unknown type.");
     require (_orderInfo.price > 0, "orderbook: price should be greater than zero.");
     require (_orderInfo.amount > 0, "orderbook: amount should be greater than zero.");

     if (_orderInfo.orderType == ORDER_TYPE_ASK) {
       emit PlaceSellOrder(_orderInfo.maker, _orderInfo.price, _orderInfo.amount, _orderInfo.tradeTokenAddress);
       _placeSellOrder(_orderInfo.maker, _orderInfo.tradeTokenAddress, _orderInfo.price, _orderInfo.amount);
     } else {
       emit PlaceBuyOrder(_orderInfo.maker, _orderInfo.price, _orderInfo.amount, _orderInfo.tradeTokenAddress);
       _placeBuyOrder(_orderInfo.maker, _orderInfo.tradeTokenAddress, _orderInfo.price, _orderInfo.amount);
     }
   }

   /**
    * @notice Place order.
    */
   function placeOrder(
     address _tradeToken,
     uint8 _orderType,  // 0: ask, 1: bid
     uint256 _price,
     uint256 _amount
   ) external nonReentrant whenNotPaused {
     require (_tradeToken != address(0), "orderbook: tradetoken can't be zero token.");
     require (_tradeToken != address(baseToken), "orderbook: can't place order with same token.");
     require (msg.sender != address(0), "orderbook: owner can't be zero address.");
     require (_orderType == 0 || _orderType == 1, "orderbook: unknown type.");
     require (_price > 0, "orderbook: price should be greater than zero.");
     require (_amount > 0, "orderbook: amount should be greater than zero.");

     if (_orderType == ORDER_TYPE_ASK) {
       _amount = transferAndCheck(_tradeToken, msg.sender, address(this), _amount);
       emit PlaceSellOrder(msg.sender, _price, _amount, _tradeToken);
       _placeSellOrder(msg.sender, _tradeToken, _price, _amount);
     } else {
       _amount = transferAndCheck(address(baseToken), msg.sender, address(this), _amount.mul(_price).div(10**18));
       emit PlaceBuyOrder(msg.sender, _price, _amount, _tradeToken);
       _placeBuyOrder(msg.sender, _tradeToken, _price, _amount);
     }
   }

   function transferAndCheck(
     address _tokenAddress,
     address _from,
     address _to,
     uint256 _value
   ) internal returns(uint256 transferedAmount) {
     IERC20 token = IERC20(_tokenAddress);
     uint256 originBalance = token.balanceOf(_to);
     token.safeTransferFrom(_from, _to, _value);
     transferedAmount = token.balanceOf(_to).sub(originBalance);
   }

   function getSplitProfit(uint256 _profitAmount) internal view returns (uint16 devProfit, uint16 matcherProfit) {
     uint256 i = 0;
     while (i < splitProfitCnt && splitProfits[i].maxProfit < _profitAmount) {
       i ++;
     }

     devProfit = splitProfits[i].devProfit;
     matcherProfit = splitProfits[i].matcherProfit;
   }

   function getTakerFee(uint256 _price) internal view returns (uint16 takerFee) {
     uint256 i = 0;
     while (i < takerFeeCnt && takerFees[i].maxPrice < _price) {
       i ++;
     }

     takerFee = takerFees[i].fee;
   }

   function getMakerFee(uint256 _price) internal view returns (uint16 makerFee) {
     uint256 i = 0;
     while (i < makerFeeCnt && makerFees[i].maxPrice < _price) {
       i ++;
     }

     makerFee = makerFees[i].fee;
   }

   function matchOrder(
     address _buyer,
     address _seller,
     address _tradeToken,
     uint256 _tradeTokenAmount,
     uint256 _baseTokenAmount,
     uint256 _price,
     uint256 _profit,
     uint8 _orderType
   ) internal {
     // transfer proper tokens to two parties
     IERC20 tradeToken = IERC20(_tradeToken);
    //  baseToken.approve(address(this), _baseTokenAmount);
    //  tradeToken.approve(address(this), _tradeTokenAmount);
     baseToken.approve(_seller, _baseTokenAmount);
     tradeToken.approve(_buyer, _tradeTokenAmount);

     // calc fee, take and maker
     uint256 buyerFee = 0;
     uint256 sellerFee = 0;
     uint256 takerFee = getTakerFee(_price);
     uint256 makerFee = getMakerFee(_price);
     if (_orderType == ORDER_TYPE_ASK) {    // buyer: maker, seller: taker
      buyerFee = _tradeTokenAmount.mul(makerFee).div(10**4);
      sellerFee = _baseTokenAmount.mul(takerFee).div(10**4);
     } else { // buyer: taker, seller: maker
      buyerFee = _tradeTokenAmount.mul(takerFee).div(10**4);
      sellerFee = _baseTokenAmount.mul(makerFee).div(10**4);
     }

     _tradeTokenAmount = _tradeTokenAmount.sub(buyerFee);
     _baseTokenAmount = _baseTokenAmount.sub(sellerFee);

    //  baseToken.safeTransferFrom(address(this), _seller, _baseTokenAmount);
    //  tradeToken.safeTransferFrom(address(this), _buyer, _tradeTokenAmount);
     baseToken.transferFrom(address(this), _seller, _baseTokenAmount);
     tradeToken.transferFrom(address(this), _buyer, _tradeTokenAmount);

     // split profit to dev and match maker
     uint256 devProfitPro;
     uint256 matcherProfitPro;
     (devProfitPro, matcherProfitPro) = getSplitProfit(_profit);
     
     uint256 devProfit = buyerFee.mul(devProfitPro).div(10**4);
     uint256 matcherProfit = buyerFee.sub(devProfit);

     tradeToken.approve(devWallet, devProfit);
     tradeToken.approve(address(this), devProfit);
     tradeToken.safeTransferFrom(address(this), devWallet, devProfit);

     devProfit = sellerFee.mul(devProfitPro).div(10**4);
     matcherProfit = sellerFee.sub(devProfit);

     baseToken.approve(devWallet, devProfit);
     baseToken.approve(address(this), devProfit);
     baseToken.safeTransferFrom(address(this), devWallet, devProfit);
     
   }

   function checkAndAddAsset(address _tokenAddress) internal {
     if (assetInfos[_tokenAddress].exist == false) {
       assetInfos[_tokenAddress].exist = true;
       assetList[assetCnt].tokenAddress = _tokenAddress;
       assetCnt ++;
     }
   }

   function _placeBuyOrder(
     address _maker,
     address _tradeToken,
     uint256 _price,
     uint256 _amount
   ) internal {
     uint256 sellPricePointer = minSellPrice[_tradeToken];
    
     uint256 amountReflect = _amount;
     if (minSellPrice[_tradeToken] > 0 && _price >= minSellPrice[_tradeToken]) {
       while (amountReflect > 0 && sellPricePointer <= _price && sellPricePointer != 0) {
         uint8 i = 0;
         uint256 higherPrice = askOrderPrices[_tradeToken][sellPricePointer].higherPrice;
         while (i < askOrderCounts[_tradeToken][sellPricePointer] && amountReflect > 0) {
           if (amountReflect >= askOrders[_tradeToken][sellPricePointer][i].amount) {
             //if the last order has been matched, delete the step
             if (i == askOrderCounts[_tradeToken][sellPricePointer] - 1) {
               if (higherPrice > 0) {
                 askOrderPrices[_tradeToken][higherPrice].lowerPrice = 0;
                 delete askOrderPrices[_tradeToken][sellPricePointer];
                 minSellPrice[_tradeToken] = higherPrice;
               }

               uint256 matchAmount = askOrders[_tradeToken][sellPricePointer][i].amount;
              //  console.log("matchAmount is ", matchAmount);
               matchOrder(
                _maker,
                askOrders[_tradeToken][sellPricePointer][i].maker, 
                _tradeToken, 
                matchAmount, 
                matchAmount.mul(sellPricePointer).div(10**18),
                sellPricePointer,
                _price.sub(sellPricePointer),
                ORDER_TYPE_BID
               );
               amountReflect = amountReflect.sub(matchAmount);

               orderInfos[askOrders[_tradeToken][sellPricePointer][i].orderID].lastUpdatedAt = block.timestamp;
               orderInfos[askOrders[_tradeToken][sellPricePointer][i].orderID].status = ORDER_STATUS_EXECUTED;
               orderInfos[askOrders[_tradeToken][sellPricePointer][i].orderID].amount = 0;
               askOrderCounts[_tradeToken][sellPricePointer] -= 1;
             }
           } else {
              askOrderPrices[_tradeToken][sellPricePointer].amount = askOrderPrices[_tradeToken][sellPricePointer].amount.sub(amountReflect);
              askOrders[_tradeToken][sellPricePointer][i].amount = askOrders[_tradeToken][sellPricePointer][i].amount.sub(amountReflect);
               matchOrder(
                _maker,
                askOrders[_tradeToken][sellPricePointer][i].maker, 
                _tradeToken, 
                amountReflect, 
                amountReflect.mul(sellPricePointer).div(10**18),
                sellPricePointer,
                _price.sub(sellPricePointer),
                ORDER_TYPE_BID
               );
              uint256 restAmount = orderInfos[askOrders[_tradeToken][sellPricePointer][i].orderID].amount;
              restAmount = restAmount.sub(amountReflect);
              amountReflect = 0;

              orderInfos[askOrders[_tradeToken][sellPricePointer][i].orderID].lastUpdatedAt = block.timestamp;
              orderInfos[askOrders[_tradeToken][sellPricePointer][i].orderID].status = ORDER_STATUS_PART_EXECUTED;
              orderInfos[askOrders[_tradeToken][sellPricePointer][i].orderID].amount = restAmount;
           }
           i ++;
         }
         sellPricePointer = higherPrice;
       }
     }
     checkAndAddAsset(address(baseToken));
     if (amountReflect > 0) {
       _drawToBuyBook(_price, amountReflect, _tradeToken, _maker);
     }
   }

   function _placeSellOrder(
     address _maker,
     address _tradeToken,
     uint256 _price,
     uint256 _amount
   ) internal {
     uint256 buyPricePointer = maxBuyPrice[_tradeToken];
     uint256 amountReflect = _amount;
     if (maxBuyPrice[_tradeToken] > 0 && _price <= maxBuyPrice[_tradeToken]) {
       while (amountReflect > 0 && buyPricePointer >= _price && buyPricePointer != 0) {
         uint8 i = 0;
         uint256 lowerPrice = bidOrderPrices[_tradeToken][buyPricePointer].lowerPrice;
         while (i < bidOrderCounts[_tradeToken][buyPricePointer] && amountReflect > 0) {
           if (amountReflect >= bidOrders[_tradeToken][buyPricePointer][i].amount) {
             //if the last order has been matched, delete the step
             if (i == bidOrderCounts[_tradeToken][buyPricePointer] - 1) {
               if (lowerPrice > 0) {
                 bidOrderPrices[_tradeToken][lowerPrice].higherPrice = 0;
                 delete bidOrderPrices[_tradeToken][buyPricePointer];
                 maxBuyPrice[_tradeToken] = lowerPrice;
               }

               uint256 matchAmount = bidOrders[_tradeToken][buyPricePointer][i].amount;
               matchOrder(
                 bidOrders[_tradeToken][buyPricePointer][i].maker, 
                 _maker, 
                 _tradeToken, 
                 matchAmount, 
                 matchAmount.mul(buyPricePointer).div(10**18),
                 buyPricePointer,
                _price.sub(buyPricePointer),
                ORDER_TYPE_ASK
                 );
               amountReflect = amountReflect.sub(matchAmount);

               orderInfos[bidOrders[_tradeToken][buyPricePointer][i].orderID].lastUpdatedAt = block.timestamp;
               orderInfos[bidOrders[_tradeToken][buyPricePointer][i].orderID].status = ORDER_STATUS_EXECUTED;
               orderInfos[bidOrders[_tradeToken][buyPricePointer][i].orderID].amount = amountReflect;
               bidOrderCounts[_tradeToken][buyPricePointer] -= 1;
             }
           } else {
              bidOrderPrices[_tradeToken][buyPricePointer].amount = bidOrderPrices[_tradeToken][buyPricePointer].amount.sub(amountReflect);
              bidOrders[_tradeToken][buyPricePointer][i].amount = bidOrders[_tradeToken][buyPricePointer][i].amount.sub(amountReflect);
              matchOrder(
                bidOrders[_tradeToken][buyPricePointer][i].maker, 
                _maker, 
                _tradeToken, 
                amountReflect, 
                amountReflect.mul(buyPricePointer).div(10**18),
                buyPricePointer,
                _price.sub(buyPricePointer),
                ORDER_TYPE_ASK
                );
              amountReflect = 0;
              orderInfos[bidOrders[_tradeToken][buyPricePointer][i].orderID].lastUpdatedAt = block.timestamp;
              orderInfos[bidOrders[_tradeToken][buyPricePointer][i].orderID].status = ORDER_STATUS_PART_EXECUTED;
              orderInfos[bidOrders[_tradeToken][buyPricePointer][i].orderID].amount = amountReflect;
           }
           i ++;
         }
         buyPricePointer = lowerPrice;
       }
     }

     /**
      * @notice draw to buy book the rest
      */
      checkAndAddAsset(_tradeToken);
      if (amountReflect > 0) {
        _drawToSellBook(_price, amountReflect, _tradeToken, _maker);
      }
   }

    /**
     * @notice draw buy order.
     */
    function _drawToBuyBook (
        uint256 _price,
        uint256 _amount,
        address _tradeToken,
        address _maker
    ) internal {
        uint256 curTime = block.timestamp;

        orderInfos[orderID] = OrderInfo(
          _tradeToken,
          _maker,
          ORDER_TYPE_BID,
          _price,
          _amount,
          0,
          curTime,
          ORDER_STATUS_OPEN,
          curTime,
          orderID
        );

        bidOrders[_tradeToken][_price][bidOrderCounts[_tradeToken][_price]] = Order(
          _maker,
          _amount,
          orderID
        );

        bidOrderCounts[_tradeToken][_price] += 1;

        orderID ++;
        orderCount ++;

        bidOrderPrices[_tradeToken][_price].amount = bidOrderPrices[_tradeToken][_price].amount.add(_amount);
        emit DrawToBuyBook(_maker, _price, _amount, _tradeToken);

        if (maxBuyPrice[_tradeToken] == 0) {
          maxBuyPrice[_tradeToken] = _price;
          return;
        }

        if (_price > maxBuyPrice[_tradeToken]) {
          bidOrderPrices[_tradeToken][maxBuyPrice[_tradeToken]].higherPrice = _price;
          bidOrderPrices[_tradeToken][maxBuyPrice[_tradeToken]].lowerPrice = maxBuyPrice[_tradeToken];
          maxBuyPrice[_tradeToken] = _price;
          return;
        }

        if (_price == maxBuyPrice[_tradeToken]) {
          return;
        }

        uint256 buyPricePointer = maxBuyPrice[_tradeToken];
        while (_price <= buyPricePointer) {
          buyPricePointer = bidOrderPrices[_tradeToken][buyPricePointer].lowerPrice;
        }

        if (_price < bidOrderPrices[_tradeToken][buyPricePointer].higherPrice) {
          bidOrderPrices[_tradeToken][_price].higherPrice = bidOrderPrices[_tradeToken][buyPricePointer].higherPrice;
          bidOrderPrices[_tradeToken][_price].lowerPrice = buyPricePointer;

          bidOrderPrices[_tradeToken][bidOrderPrices[_tradeToken][buyPricePointer].higherPrice].lowerPrice = _price;
          bidOrderPrices[_tradeToken][buyPricePointer].higherPrice = _price;
        }
    }

    /**
     * @notice draw sell order.
     */
    function _drawToSellBook (
        uint256 _price,
        uint256 _amount,
        address _tradeToken,
        address _maker
    ) internal {
      uint256 curTime = block.timestamp;

      orderInfos[orderID] = OrderInfo(
        _tradeToken,
        _maker,
        ORDER_TYPE_ASK,
        _price,
        _amount,
        0,
        curTime,
        ORDER_STATUS_OPEN,
        curTime,
        orderID
      );

      askOrders[_tradeToken][_price][bidOrderCounts[_tradeToken][_price]] = Order(
        _maker,
        _amount,
        orderID
      );

      orderID ++;
      orderCount ++;
      askOrderCounts[_tradeToken][_price] += 1;

      askOrderPrices[_tradeToken][_price].amount = askOrderPrices[_tradeToken][_price].amount.add(_amount);
      emit DrawToSellBook(_maker, _price, _amount, _tradeToken);

      if (minSellPrice[_tradeToken] == 0) {
        minSellPrice[_tradeToken] = _price;
        return;
      }

      if (_price < minSellPrice[_tradeToken]) {
        askOrderPrices[_tradeToken][minSellPrice[_tradeToken]].lowerPrice = _price;
        askOrderPrices[_tradeToken][minSellPrice[_tradeToken]].higherPrice = minSellPrice[_tradeToken];
        minSellPrice[_tradeToken] = _price;
        return;
      }

      if (_price == minSellPrice[_tradeToken]) {
        return;
      }

      uint256 sellPricePointer = minSellPrice[_tradeToken];
      while (_price >= sellPricePointer) {
        sellPricePointer = askOrderPrices[_tradeToken][sellPricePointer].higherPrice;
      }

      if (sellPricePointer > _price && _price > askOrderPrices[_tradeToken][sellPricePointer].lowerPrice) {
        askOrderPrices[_tradeToken][_price].lowerPrice = askOrderPrices[_tradeToken][sellPricePointer].lowerPrice;
        askOrderPrices[_tradeToken][_price].higherPrice = sellPricePointer;

        askOrderPrices[_tradeToken][askOrderPrices[_tradeToken][sellPricePointer].lowerPrice].higherPrice = _price;
        bidOrderPrices[_tradeToken][sellPricePointer].lowerPrice = _price;
      }
    }

   function pause() external onlyOwner {
     _pause();
   }

   function release() external onlyOwner {
     _unpause();
   }

   function getOrderCount() external view returns(uint256 count) {
     count = orderCount;
   }

   function getAllOrders() external view returns (OrderInfo[] memory) {
     uint256 i = 0;
     uint256 index = 0;
     OrderInfo[] memory response = new OrderInfo[](orderCount);

     for (i = 0; i < orderID; i ++) {
       if (orderInfos[i].maker != address(0) && orderInfos[i].status != ORDER_STATUS_CLOSED) {
         response[index ++] = orderInfos[i];
       }
     }

     return response;
   }

   function getOrderByID(uint256 _orderID) external view returns (OrderInfo memory) {
     require (orderInfos[_orderID].status != ORDER_STATUS_CLOSED, "orderbook: this order is closed.");
     return orderInfos[_orderID];
   }

   function getAssetList() public view onlyOwner returns (AssetListInfo[] memory) {
     uint256 i = 0;
     AssetListInfo[] memory _assetList = new AssetListInfo[](assetCnt);
     for (i = 0; i < assetCnt; i ++) {
       _assetList[i] = assetList[i];
       IERC20 token = IERC20(assetList[i].tokenAddress);
       _assetList[i].amount = token.balanceOf(address(this));
     }

     return _assetList;
   }

   function withDrawAll() external whenPaused onlyOwner {
     uint256 i = 0;
     AssetListInfo[] memory _assetList = getAssetList();
     for (i = 0; i < assetCnt; i ++) {
       address tokenAddress = _assetList[i].tokenAddress;
       IERC20 token = IERC20(tokenAddress);
       if (_assetList[i].amount > 0) {
         token.approve(address(this), _assetList[i].amount);
         token.approve(owner(), _assetList[i].amount);

         token.safeTransferFrom(address(this), owner(), _assetList[i].amount);
       }
     }
   }

   function getAssetCount() external view onlyOwner returns (uint256) {
     return assetCnt;
   }

   function getTokenBalance(address _tokenAddress) external view returns (uint256 balance) {
     IERC20 token = IERC20(_tokenAddress);
     balance = token.balanceOf(msg.sender);
   }

   function getCurOrderID() external view returns(uint256) {
     return orderID;
   }

   function close(uint256 _orderID) public {
     require (msg.sender == orderInfos[_orderID].maker && orderInfos[_orderID].maker != address(0), "orderbook: not order owner.");
     require (orderInfos[_orderID].status != ORDER_STATUS_CLOSED, "orderbook: already closed.");

     deleteOrder(_orderID);
   }

   function deleteOrder(uint256 _orderID) internal {
     address tokenAddress = orderInfos[_orderID].tradeTokenAddress;
     uint256 price = orderInfos[_orderID].price;
     uint256 restAmount = orderInfos[_orderID].amount;
     uint8 orderType = orderInfos[_orderID].orderType;
     uint8 status = orderInfos[_orderID].status;

     if (status == ORDER_STATUS_EXECUTED) {
       orderInfos[_orderID].status = ORDER_STATUS_CLOSED;
       orderCount --;
       return;
     }


     if (orderType == ORDER_TYPE_ASK) {
       if (restAmount > 0) {
        // refund
        address makerAddress = orderInfos[_orderID].maker;
        IERC20 tradeToken = IERC20(tokenAddress);
        tradeToken.approve(address(this), restAmount);
        tradeToken.approve(makerAddress, restAmount);
        transferAndCheck(tokenAddress, address(this), makerAddress, restAmount);
       }

       uint256 cnt = askOrderCounts[tokenAddress][price];
       uint i = 0;
       for (i = 0; i < cnt; i ++) {
         if (askOrders[tokenAddress][price][i].orderID == _orderID) {
           delete askOrders[tokenAddress][price][i];
           orderCount --;
           orderInfos[_orderID].status = ORDER_STATUS_CLOSED;
           orderInfos[_orderID].amount = 0;
           askOrderCounts[tokenAddress][price] = cnt.sub(1);
           uint256 higher = askOrderPrices[tokenAddress][price].higherPrice;
           uint256 lower = askOrderPrices[tokenAddress][price].lowerPrice;

           if (higher != 0) {
             if (lower != 0) {
               askOrderPrices[tokenAddress][lower].higherPrice = higher;
               askOrderPrices[tokenAddress][higher].lowerPrice = lower;
             } else {
               askOrderPrices[tokenAddress][higher].lowerPrice = 0;
             }
           } else {
             if (lower != 0) {
               askOrderPrices[tokenAddress][lower].higherPrice = 0;
             }
           }

           if (lower != 0) {
             if (higher != 0) {
             } else {
               askOrderPrices[tokenAddress][lower].higherPrice = 0;
             }
           } else {
             if (higher != 0) {
               askOrderPrices[tokenAddress][higher].lowerPrice = 0;
             }
           }
         }
       }
     } else {
       if (restAmount > 0) {
        // refund
        address makerAddress = orderInfos[_orderID].maker;
        uint256 baseTokenAmount = restAmount.mul(price).div(10**18);
        baseToken.approve(address(this), baseTokenAmount);
        baseToken.approve(makerAddress, baseTokenAmount);
        transferAndCheck(address(baseToken), address(this), makerAddress, baseTokenAmount);
       }
       uint i = 0;
       uint256 cnt = bidOrderCounts[tokenAddress][price];
       for (i = 0; i < cnt; i ++) {
         if (bidOrders[tokenAddress][price][i].orderID == _orderID) {
           delete bidOrders[tokenAddress][price][i];
           orderCount --;
           orderInfos[_orderID].status = ORDER_STATUS_CLOSED;
           orderInfos[_orderID].amount = 0;
           bidOrderCounts[tokenAddress][price] = cnt.sub(1);
           uint256 higher = bidOrderPrices[tokenAddress][price].higherPrice;
           uint256 lower = bidOrderPrices[tokenAddress][price].lowerPrice;

           if (higher != 0) {
             if (lower != 0) {
               bidOrderPrices[tokenAddress][lower].higherPrice = higher;
               bidOrderPrices[tokenAddress][higher].lowerPrice = lower;
             } else {
               bidOrderPrices[tokenAddress][higher].lowerPrice = 0;
             }
           } else {
             if (lower != 0) {
               bidOrderPrices[tokenAddress][lower].higherPrice = 0;
             }
           }

           if (lower != 0) {
             if (higher != 0) {
             } else {
               bidOrderPrices[tokenAddress][lower].higherPrice = 0;
             }
           } else {
             if (higher != 0) {
               bidOrderPrices[tokenAddress][higher].lowerPrice = 0;
             }
           }
         }
       }
     }
   }
   
   function updateOrder(uint256 _orderID, uint256 _price, uint256 _amount) external {
     require (msg.sender == orderInfos[_orderID].maker && orderInfos[_orderID].maker != address(0), "orderbook: not order owner.");
     require (orderInfos[_orderID].status != ORDER_STATUS_CLOSED, "orderbook: already closed.");

     OrderInfo memory orderInfo = orderInfos[_orderID];
     orderInfos[_orderID].amount = 0;
     deleteOrder(_orderID);

     if (orderInfo.orderType == ORDER_TYPE_ASK) {
       if (_amount < orderInfo.amount) {
         // refund
         uint256 refundAmount = (orderInfo.amount).sub(_amount);
         IERC20 tradeToken = IERC20(orderInfo.tradeTokenAddress);
         tradeToken.approve(address(this), refundAmount);
         tradeToken.approve(msg.sender, refundAmount);
         tradeToken.safeTransferFrom(address(this), msg.sender, refundAmount);
       } else {
         transferAndCheck(orderInfo.tradeTokenAddress, msg.sender, address(this), _amount.sub(orderInfo.amount));
       }
       
       emit PlaceSellOrder(msg.sender, _price, _amount, orderInfo.tradeTokenAddress);
       _placeSellOrder(msg.sender, orderInfo.tradeTokenAddress, _price, _amount);
     } else {
       uint256 originAmount = (orderInfo.price).mul(orderInfo.amount);
       uint256 newAmount = _price.mul(_amount);

       if (originAmount > newAmount) {
        // refund
        uint256 refundAmount = originAmount.sub(newAmount);
        refundAmount = refundAmount.div(10**18);
        baseToken.approve(address(this), refundAmount);
        baseToken.approve(msg.sender, refundAmount);
        baseToken.safeTransferFrom(address(this), msg.sender, refundAmount);
       } else {
         uint256 desiredAmount = newAmount.sub(originAmount);
        transferAndCheck(address(baseToken), msg.sender, address(this), desiredAmount.div(10**18));
       }
       emit PlaceBuyOrder(msg.sender, _price, _amount, orderInfo.tradeTokenAddress);
       _placeBuyOrder(msg.sender, orderInfo.tradeTokenAddress, _price, _amount);
     }    
   }
}