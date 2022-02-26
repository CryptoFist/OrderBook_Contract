// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

/**
 * @title Interface for OrderBook
 */
interface IOrderBook {

  struct OrderInfo {
    address tradeTokenAddress;
    address maker;
    uint8 orderType;
    uint256 price;
    uint256 amount;
    uint256 debtAmount;
    uint256 createdAt;
    uint8 status;
    uint256 lastUpdatedAt;
  }

  struct Order {
    address maker;
    uint256 amount;
    uint256 orderID;
  }

  struct OrderPrice {
    uint256 price;
    uint256 higherPrice;
    uint256 lowerPrice;
    uint256 amount;
  }

  struct FeeRule {
    uint256 maxPrice;
    uint16 fee; // % * 10**2, 300 => 0.03%
  }

  struct ProfitRule {
    uint256 maxProfit;
    uint16 devProfit;
    uint16 matcherProfit;
  }

  struct AssetInfo {
    uint256 amount;
    bool exist;
  }

  event PlaceBuyOrder(address _maker, uint256 price, uint256 amountOfBaseToken, address tradeToken);
  event PlaceSellOrder(address _maker, uint256 price, uint256 amountOfTradeToken, address tradeToken);
  event DrawToSellBook(address sender, uint256 price, uint256 amountOfTradeToken, address tradeToken);
  event DrawToBuyBook(address sender, uint256 price, uint256 amountOfBaseToken, address tradeToken);
}