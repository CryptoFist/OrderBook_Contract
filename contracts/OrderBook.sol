// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract OrderBook is ReentrancyGuard, Pausable, Ownable {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  IERC20 private baseToken;

  enum OrderType {
    BID,
    ASK
  }

  enum OrderStatus {
    OPEN,
    PARTICALLY_EXECUTED,
    EXECUTED,
    CLOSE
  }

  /**
   * @notice constructor 
   */
   constructor(address _baseToken) {
     baseToken = IERC20(_baseToken);
   }

   function setOrder(
     address _tradeToken,
     address _orderOwner,
     uint8 _orderType,
     uint256 _orderPrice,
     uint256 _orderAmount,
     uint256 _createdAt,
     uint8 _orderStatus,
     uint256 _lastUpdatedAt,
     uint256 _courseID
   ) external payable nonReentrant {

   }

   function matchOrder(
     uint256 _bidOrderID,
     uint256 _askOrderID
   ) external nonReentrant {

   }

   function pause() external onlyOwner {
     _pause();
   }
}