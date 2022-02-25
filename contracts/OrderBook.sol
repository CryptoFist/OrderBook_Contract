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

  mapping(uint256 => OrderInfo) private askOrderInfos;  // orderID => orderInfo
  mapping(address => mapping(uint256 => mapping(uint256 => Order))) private askOrders; // tradeTokenAddress => price => index => Order
  mapping(address => mapping(uint256 => OrderPrice)) private askOrderPrices; // tradeTokenAddress => price => OrderPrice
  mapping(address => mapping(uint256 => uint256)) private askOrderCounts; // tradeTokenAddress => price => count
  mapping(address => uint256) private minSellPrice;  // tradeTokenAddress => minSellPrice
  uint256 private askOrderCount;
  
  mapping(uint256 => OrderInfo) private bidOrderInfos;  // orderID => orderInfo
  mapping(address => mapping(uint256 => mapping(uint256 => Order))) private bidOrders; // tradeTokenAddress => price => index =>Order
  mapping(address => mapping(uint256 => OrderPrice)) private bidOrderPrices; // tradeTokenAddress => price => OrderPrice
  mapping(address => mapping(uint256 => uint256)) private bidOrderCounts; // tradeTokenAddress => price => count
  mapping(address => uint256) private maxBuyPrice;  // tradeTokenAddress => maxSellPrice
  uint256 private bidOrderCount;

  uint8 private ORDER_TYPE_ASK = 0;
  uint8 private ORDER_TYPE_BID = 1;

  uint8 private ORDER_STATUS_OPEN = 0;
  uint8 private ORDER_STATUS_PART_EXECUTED = 1;
  uint8 private ORDER_STATUS_EXECUTED = 2;
  uint8 private ORDER_STATUS_CLOSED = 3;

  /**
   * @notice constructor 
   */
   constructor(address _baseToken) {
     baseToken = IERC20(_baseToken);
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
     require (msg.sender != address(0), "orderbook: owner can't be zero address.");
     require (_orderType == 0 || _orderType == 1, "orderbook: unknown type.");
     require (_price > 0, "orderbook: price should be greater than zero.");
     require (_amount > 0, "orderbook: amount should be greater than zero.");

     if (_orderType == ORDER_TYPE_ASK) {
       _placeSellOrder(msg.sender, _tradeToken, _price, _amount);
     } else {
       _placeBuyOrder(msg.sender, _tradeToken, _price, _amount);
     }
   }

   function transferAndCheck(
     address _tokenAddress,
     address _from,
     address _to,
     uint256 _value
   ) internal returns(uint256 transferedValue) {
     IERC20 token = IERC20(_tokenAddress);
     uint256 originBalance = token.balanceOf(_to);
     token.safeTransferFrom(_from, _to, _value);
     transferedValue = token.balanceOf(_to).sub(originBalance);
   }

   function matchOrder(
     address _buyer,
     address _seller,
     address _tradeToken,
     uint256 _tradeTokenAmount,
     uint256 _baseTokenAmount,
     uint256 _restAmount
   ) internal {
     // transfer proper tokens to two parties
     IERC20 tradeToken = IERC20(_tradeToken);
     baseToken.safeApprove(address(this), _baseTokenAmount.add(_restAmount));
     tradeToken.safeApprove(address(this), _tradeTokenAmount);
     baseToken.safeApprove(_seller, _baseTokenAmount.add(_restAmount));
     tradeToken.safeApprove(_buyer, _tradeTokenAmount);

     baseToken.safeTransferFrom(address(this), _seller, _baseTokenAmount);
     tradeToken.safeTransferFrom(address(this), _buyer, _tradeTokenAmount);

     // calc fee, take and maker
     // split profit to dev and match maker

     baseToken.safeTransferFrom(address(this), _buyer, _restAmount);
   }

   function _placeBuyOrder(
     address _maker,
     address _tradeToken,
     uint256 _price,
     uint256 _amount
   ) internal {
     transferAndCheck(address(baseToken), _maker, address(this), _amount.mul(_price).div(10**18));
     emit PlaceBuyOrder(_maker, _price, _amount, _tradeToken);

     uint256 sellPricePointer = minSellPrice[_tradeToken];
    
     uint256 amountReflect = _amount;
     if (minSellPrice[_tradeToken] > 0 && _price >= minSellPrice[_tradeToken]) {
       while (amountReflect > 0 && sellPricePointer <= _price && sellPricePointer != 0) {
         uint8 i = 0;
         uint256 higherPrice = askOrderPrices[_tradeToken][sellPricePointer].higherPrice;
         while (i <= askOrderCounts[_tradeToken][sellPricePointer] && amountReflect > 0) {
           if (amountReflect >= askOrders[_tradeToken][sellPricePointer][i].amount) {
             //if the last order has been matched, delete the step
             if (i == askOrderCounts[_tradeToken][sellPricePointer] - 1) {
               if (higherPrice > 0) {
                 askOrderPrices[_tradeToken][higherPrice].lowerPrice = 0;
                 delete askOrderPrices[_tradeToken][sellPricePointer];
                 minSellPrice[_tradeToken] = higherPrice;
               }

               uint256 matchAmount = askOrders[_tradeToken][sellPricePointer][i].amount;
               uint256 priceOffset = _price.sub(sellPricePointer);
               matchOrder(
                _maker,
                askOrders[_tradeToken][sellPricePointer][i].maker, 
                _tradeToken, 
                matchAmount, 
                matchAmount.mul(sellPricePointer).div(10**18),
                matchAmount.mul(priceOffset).div(10**18)
               );
               amountReflect = amountReflect.sub(matchAmount);

               askOrderInfos[askOrders[_tradeToken][sellPricePointer][i].orderID].lastUpdatedAt = block.timestamp;
               askOrderInfos[askOrders[_tradeToken][sellPricePointer][i].orderID].status = ORDER_STATUS_EXECUTED;
               askOrderCounts[_tradeToken][sellPricePointer] -= 1;
             }
           } else {
              askOrderPrices[_tradeToken][sellPricePointer].amount = askOrderPrices[_tradeToken][sellPricePointer].amount.sub(amountReflect);
              askOrders[_tradeToken][sellPricePointer][i].amount = askOrders[_tradeToken][sellPricePointer][i].amount.sub(amountReflect);
              uint256 priceOffset = _price.sub(sellPricePointer);
              matchOrder(
                _maker,
                askOrders[_tradeToken][sellPricePointer][i].maker, 
                _tradeToken, 
                amountReflect, 
                amountReflect.mul(sellPricePointer).div(10**18), 
                amountReflect.mul(priceOffset).div(10**18)
               );
              amountReflect = 0;

              askOrderInfos[askOrders[_tradeToken][sellPricePointer][i].orderID].lastUpdatedAt = block.timestamp;
              askOrderInfos[askOrders[_tradeToken][sellPricePointer][i].orderID].status = ORDER_STATUS_PART_EXECUTED;
           }
           i ++;
         }
         sellPricePointer = higherPrice;
       }
     }

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
     _amount = transferAndCheck(_tradeToken, _maker, address(this), _amount);
     emit PlaceSellOrder(_maker, _price, _amount, _tradeToken);

     uint256 buyPricePointer = maxBuyPrice[_tradeToken];
     uint256 amountReflect = _amount;
     if (maxBuyPrice[_tradeToken] > 0 && _price <= maxBuyPrice[_tradeToken]) {
       while (amountReflect > 0 && buyPricePointer >= _price && buyPricePointer != 0) {
         uint8 i = 0;
         uint256 lowerPrice = bidOrderPrices[_tradeToken][buyPricePointer].lowerPrice;
         while (i <= bidOrderCounts[_tradeToken][buyPricePointer] && amountReflect > 0) {
           if (amountReflect >= bidOrders[_tradeToken][buyPricePointer][i].amount) {
             //if the last order has been matched, delete the step
             if (i == bidOrderCounts[_tradeToken][buyPricePointer] - 1) {
               if (lowerPrice > 0) {
                 bidOrderPrices[_tradeToken][lowerPrice].higherPrice = 0;
                 delete bidOrderPrices[_tradeToken][buyPricePointer];
                 maxBuyPrice[_tradeToken] = lowerPrice;
               }

               uint256 matchAmount = bidOrders[_tradeToken][buyPricePointer][i].amount;
               uint256 priceOffset = buyPricePointer.sub(_price);
               matchOrder(
                 bidOrders[_tradeToken][buyPricePointer][i].maker, 
                 _maker, 
                 _tradeToken, 
                 matchAmount, 
                 matchAmount.mul(buyPricePointer).div(10**18), 
                 matchAmount.mul(priceOffset).div(10**18)
                 );
               amountReflect = amountReflect.sub(matchAmount);

               bidOrderInfos[bidOrders[_tradeToken][buyPricePointer][i].orderID].lastUpdatedAt = block.timestamp;
               bidOrderInfos[bidOrders[_tradeToken][buyPricePointer][i].orderID].status = ORDER_STATUS_EXECUTED;
               bidOrderCounts[_tradeToken][buyPricePointer] -= 1;
             }
           } else {
              bidOrderPrices[_tradeToken][buyPricePointer].amount = bidOrderPrices[_tradeToken][buyPricePointer].amount.sub(amountReflect);
              bidOrders[_tradeToken][buyPricePointer][i].amount = bidOrders[_tradeToken][buyPricePointer][i].amount.sub(amountReflect);
              uint256 priceOffset = buyPricePointer.sub(_price);
              matchOrder(
                bidOrders[_tradeToken][buyPricePointer][i].maker, 
                _maker, 
                _tradeToken, 
                amountReflect, 
                amountReflect.mul(buyPricePointer).div(10**18), 
                amountReflect.mul(priceOffset).div(10**18)
                );
              amountReflect = 0;
              bidOrderInfos[bidOrders[_tradeToken][buyPricePointer][i].orderID].lastUpdatedAt = block.timestamp;
              bidOrderInfos[bidOrders[_tradeToken][buyPricePointer][i].orderID].status = ORDER_STATUS_PART_EXECUTED;
           }
           i ++;
         }
         buyPricePointer = lowerPrice;
       }
     }

     /**
      * @notice draw to buy book the rest
      */
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

        bidOrderInfos[orderID] = OrderInfo(
          _tradeToken,
          _maker,
          ORDER_TYPE_ASK,
          _price,
          _amount,
          curTime,
          ORDER_STATUS_OPEN,
          curTime
        );

        bidOrders[_tradeToken][_price][bidOrderCounts[_tradeToken][_price]] = Order(
          _maker,
          _amount,
          orderID
        );

        bidOrderCounts[_tradeToken][_price] += 1;

        orderID ++;
        bidOrderCount ++;

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

      askOrderInfos[orderID] = OrderInfo(
        _tradeToken,
        _maker,
        ORDER_TYPE_ASK,
        _price,
        _amount,
        curTime,
        ORDER_STATUS_OPEN,
        curTime
      );

      askOrders[_tradeToken][_price][bidOrderCounts[_tradeToken][_price]] = Order(
        _maker,
        _amount,
        orderID
      );

      orderID ++;
      askOrderCount ++;
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

   function getAskOrderCount() external view returns (uint256) {
     return askOrderCount;
   }

   function getBidOrderCount() external view returns (uint256) {
     return bidOrderCount;
   }

   function getAllAskOrders() external view returns (OrderInfo[] memory) {
     uint256 i = 0;
     OrderInfo[] memory response = new OrderInfo[](askOrderCount);

     for (i = 0; i < orderID; i ++) {
       response[i] = askOrderInfos[i];
     }

     return response;
   }

   function getAllBidOrders() external view returns (OrderInfo[] memory) {
     uint256 i = 0;
     OrderInfo[] memory response = new OrderInfo[](bidOrderCount);

     for (i = 0; i < orderID; i ++) {
       response[i] = bidOrderInfos[i];
     }

     return response;
   }
}