// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

/**
 * @title Interface for OrderBook
 */
interface IOrderBook {
  struct Order {
    address tradeTokenAddress;
    address maker;
    uint8 orderType;
    uint256 price;
    uint256 amount;
    uint256 createdAt;
    uint8 status;
    uint256 lastUpdatedAt;
  }

  struct OrderPrice {
    uint256 price;
    uint256 higherPrice;
    uint256 lowerPrice;
    uint256 amount;
  }

  event PlaceBuyOrder(address _maker, uint256 price, uint256 amountOfBaseToken, address tradeToken);
  event PlaceSellOrder(address _maker, uint256 price, uint256 amountOfTradeToken, address tradeToken);
  event DrawToSellBook(address sender, uint256 price, uint256 amountOfTradeToken, address tradeToken);
  event DrawToBuyBook(address sender, uint256 price, uint256 amountOfBaseToken, address tradeToken);
}