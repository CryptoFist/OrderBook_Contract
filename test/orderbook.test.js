const { expect, assert } = require('chai');
const { BigNumber, parse } = require('ethers');
const { ethers } = require('hardhat');

const bigNum = num => (num + '0'.repeat(18))
const smallNum = num =>(parseInt(num)/bigNum(1))

describe('orderbook contract', function () {
  before (async function () {
    // const [owner, addr1] = await ethers.getSigners();
    [
      this.owner,
      this.dev,
      this.alice,
      this.bob,
      this.empty
    ] = await ethers.getSigners();

    this.usdc = await ethers.getContractFactory('ERC20Mock');
    this.usdc = await this.usdc.deploy('USDC', 'USDC');
    await this.usdc.deployed();

    this.btc = await ethers.getContractFactory('ERC20Mock');
    this.btc = await this.btc.deploy('BitCoin', 'BTC');
    await this.btc.deployed();

    this.eth = await ethers.getContractFactory('ERC20Mock');
    this.eth = await this.eth.deploy('Ethereum', 'ETH');
    await this.eth.deployed();

    this.usdt = await ethers.getContractFactory('ERC20Mock');
    this.usdt = await this.usdt.deploy('USDT', 'USDT');
    await this.usdt.deployed();

    this.orderbookContract = await ethers.getContractFactory('OrderBook');
    this.orderbookContract = await this.orderbookContract.deploy(this.usdc.address, this.dev.address);
    await this.orderbookContract.deployed();
    console.log(`orderbook contract address is ${this.orderbookContract.address}`);
  })

  beforeEach(async function() {
    await this.usdc.connect(this.owner).approve(this.orderbookContract.address, bigNum(250000));
    await this.btc.connect(this.owner).approve(this.orderbookContract.address, bigNum(250000));
    await this.eth.connect(this.owner).approve(this.orderbookContract.address, bigNum(250000));

    await this.usdc.connect(this.alice).approve(this.orderbookContract.address, bigNum(250000));
    await this.btc.connect(this.alice).approve(this.orderbookContract.address, bigNum(250000));
    await this.eth.connect(this.alice).approve(this.orderbookContract.address, bigNum(250000));

    await this.usdc.connect(this.bob).approve(this.orderbookContract.address, bigNum(100000000));
    await this.btc.connect(this.bob).approve(this.orderbookContract.address, bigNum(100000000));
    await this.eth.connect(this.bob).approve(this.orderbookContract.address, bigNum(100000000));
  })

  it ('place new ask order with btc token from alice should be success', async function () {
    await this.btc.connect(this.owner).approve(this.alice.address, bigNum(250000));
    await this.btc.connect(this.owner).transfer(this.alice.address, bigNum(1500));

    let btcBalance = await this.btc.balanceOf(this.alice.address);

    await this.orderbookContract.connect(this.alice).placeOrder(
      this.btc.address,
      0,  // ask
      bigNum(30), // 30 USDC
      bigNum(50) // 50 BTC 
    );

    btcBalance = btcBalance - await this.btc.balanceOf(this.alice.address);
    const orderCount = await this.orderbookContract.getOrderCount();
    const contractBtcBalance = await this.btc.balanceOf(this.orderbookContract.address);

    assert.equal(BigInt(orderCount), 1);
    assert.equal(BigInt(btcBalance), BigInt(50 * 10**18));
    assert.equal(BigInt(contractBtcBalance), BigInt(50 * 10**18));
  })

  it ('place new bid order with eth token from alice wallet should be success', async function () {
    await this.usdc.connect(this.owner).approve(this.alice.address, bigNum(250000));
    await this.usdc.connect(this.owner).transfer(this.alice.address, bigNum(500));

    let balance = await this.usdc.balanceOf(this.alice.address);

    await this.orderbookContract.connect(this.alice).placeOrder(
      this.eth.address,
      1,  // bid
      bigNum(10), // 10 USDC
      bigNum(50) // 50 ETH
    );

    balance = balance - await this.usdc.balanceOf(this.alice.address);
    const orderCount = await this.orderbookContract.getOrderCount();
    const contractBtcBalance = await this.usdc.balanceOf(this.orderbookContract.address);

    assert.equal(BigInt(orderCount), 2);
    assert.equal(BigInt(balance), bigNum(500));
    assert.equal(BigInt(contractBtcBalance), bigNum(500));
  })

  it ('place new bid order that matches part of ask order', async function () {
    const btcBalance = await this.btc.balanceOf(this.owner.address);
    const usdcBalance = await this.usdc.balanceOf(this.alice.address);
    const ownerUSDCBalance = await this.usdc.balanceOf(this.owner.address);
    const originAmount = (await this.orderbookContract.getOrderByID(0)).amount;

    await this.orderbookContract.connect(this.owner).placeOrder(
      this.btc.address,
      1,  // bid
      bigNum(31), // 31 USDC
      bigNum(30) // 30 BTC
    );

    const newBtcBalance = await this.btc.balanceOf(this.owner.address);
    const newOwnerUSDCBalance = await this.usdc.balanceOf(this.owner.address);
    let receivedBalance = smallNum(newBtcBalance) - smallNum(btcBalance);
    let transferedBalance = smallNum(ownerUSDCBalance) - smallNum(newOwnerUSDCBalance);
    assert.equal(receivedBalance, 30);
    assert.equal(transferedBalance, 930);

    const newUSDCBalance = await this.usdc.balanceOf(this.alice.address);
    receivedBalance = smallNum(newUSDCBalance) - smallNum(usdcBalance);
    assert.equal(receivedBalance, 900);

    const orderCount = await this.orderbookContract.getOrderCount();
    assert.equal(orderCount, 2);

    const newAmount = (await this.orderbookContract.getOrderByID(0)).amount;
    const matchedAmount = smallNum(originAmount) - smallNum(newAmount);
    assert.equal(matchedAmount, 30);
  })
  
  it ('place new bid order that matches ask order', async function () {

    const btcBalance = await this.btc.balanceOf(this.owner.address);
    const usdcBalance = await this.usdc.balanceOf(this.alice.address);
    const ownerUSDCBalance = await this.usdc.balanceOf(this.owner.address);

    await this.orderbookContract.placeOrder(
      this.btc.address,
      1,  // bid
      bigNum(40), // 40 USDC
      bigNum(25) // 20 BTC
    );

    const newOwnerUSDCBalance = await this.usdc.balanceOf(this.owner.address);
    const newBtcBalance = await this.btc.balanceOf(this.owner.address);
    let receivedBalance = smallNum(newBtcBalance) - smallNum(btcBalance);
    const transferedBalance = smallNum(ownerUSDCBalance) - smallNum(newOwnerUSDCBalance);
    assert.equal(receivedBalance, 20);
    assert.equal(transferedBalance, 1000);

    const newUSDCBalance = await this.usdc.balanceOf(this.alice.address);
    receivedBalance = smallNum(newUSDCBalance) - smallNum(usdcBalance);
    assert.equal(receivedBalance, 600);

    const orderCount = await this.orderbookContract.getOrderCount();
    assert.equal(orderCount, 3);

    const firstOrder = await this.orderbookContract.getOrderByID(0);
    assert.equal(smallNum(firstOrder.amount), 0);
    assert.equal(firstOrder.status, 2);

    const newOrder = await this.orderbookContract.getOrderByID(2);
    assert.equal(smallNum(newOrder.amount), 5);
    assert.equal(smallNum(newOrder.price), 40);

    const orders = await this.orderbookContract.getAllOrders();
    assert.equal(orders[0].orderID, 0);
    assert.equal(orders[1].orderID, 1);
    assert.equal(orders[2].orderID, 2);
  })

  it ('place new ask order without enough balance should be fail.', async function () {
    await expect(this.orderbookContract.connect(this.empty).placeOrder(
      this.btc.address,
      0,  // ask
      bigNum(30), // 30 USDC
      bigNum(50) // 50 BTC 
    )).to.be.revertedWith("");
  })

  it ('place new bid order with wrong bid type should be fail', async function () {
    await expect(this.orderbookContract.connect(this.empty).placeOrder(
      this.btc.address,
      2,  // bid
      bigNum(30), // 30 USDC
      bigNum(50) // 50 BTC 
    )).to.be.revertedWith("orderbook: unknown type.");
  })

  it ('close order that already excuted', async function () {
    let orders = await this.orderbookContract.getAllOrders();
    const originBalance = await this.btc.balanceOf(this.alice.address);

    await this.orderbookContract.connect(this.alice).close(orders[0].orderID);
    orders = await this.orderbookContract.getAllOrders();
    assert.equal(orders[0].orderID, 1);
    assert.equal(orders[1].orderID, 2);

    const newBalance = await this.btc.balanceOf(this.alice.address);
    assert.equal(smallNum(newBalance) - smallNum(originBalance), 0);
  })

  it ('add new ask order should be success', async function () {
    await this.eth.connect(this.owner).approve(this.alice.address, bigNum(250000));
    await this.eth.connect(this.owner).transfer(this.alice.address, bigNum(500));

    await this.orderbookContract.connect(this.alice).placeOrder(
      this.eth.address,
      0, // ask
      bigNum(50), // 50 USDC
      bigNum(10)  // 10 ETH
    );

    const orderCount = await this.orderbookContract.getOrderCount();
    assert.equal(orderCount, 3);

    const orders = await this.orderbookContract.getAllOrders();
    assert.equal(orders.length, 3);

    assert.equal(orders[0].orderID, 1);
    assert.equal(orders[1].orderID, 2);
    assert.equal(orders[2].orderID, 3);
  })

  it ('close first order and check refund', async function () {
    let orders = await this.orderbookContract.getAllOrders();
    const originBalance = await this.usdc.balanceOf(this.alice.address);
    await this.orderbookContract.connect(this.alice).close(orders[0].orderID);
    const newBalance = await this.usdc.balanceOf(this.alice.address);
    assert.equal(smallNum(newBalance) - smallNum(originBalance),500);

    orders = await this.orderbookContract.getAllOrders();
    assert.equal(orders.length, 2);

    assert.equal(orders[0].orderID, 2);
    assert.equal(orders[1].orderID, 3);
  })

  it ('place bid order with base token should be fail.', async function () {
    await expect(this.orderbookContract.placeOrder(
      this.usdc.address,
      0,  // ask
      bigNum(30), // 30 USDC
      bigNum(50) // 50 USDC
    )).to.be.revertedWith("orderbook: can't place order with same token.");
  })

  it ('update order and check refund', async function () {
    let orders = await this.orderbookContract.getAllOrders();
    const originBalance = await this.usdc.balanceOf(this.owner.address);
    await this.orderbookContract.updateOrder(orders[0].orderID, bigNum(40), bigNum(1));
    const newBalance = await this.usdc.balanceOf(this.owner.address);

    const receivedAmount = smallNum(newBalance) - smallNum(originBalance);
    assert.equal(receivedAmount, 160);
  })

  it ('update last order and check payment', async function () {
    let orders = await this.orderbookContract.getAllOrders();
    let length = orders.length;
    const originBalance = await this.usdc.balanceOf(this.owner.address);
    await this.orderbookContract.updateOrder(orders[length - 1].orderID, bigNum(40), bigNum(5));
    const newBalance = await this.usdc.balanceOf(this.owner.address);

    await this.usdc.approve(this.orderbookContract.address, bigNum(200));
    
    const paidAmount = smallNum(originBalance) - smallNum(newBalance);
    assert.equal(paidAmount, 160);
  })

  it ('pause contract with not owner should be fail.', async function () {
    await expect(this.orderbookContract.connect(this.empty).pause()).to.be.revertedWith("");    
  })

  it ('pause contract and check the function call', async function () {
    await this.orderbookContract.pause();
    await expect(this.orderbookContract.placeOrder(
      this.usdc.address,
      0,  // ask
      bigNum(30), // 30 USDC
      bigNum(50) // 50 USDC
    )).to.be.revertedWith("");
  })

  it ('deploy new orderbook contract and copy data from old contract to new contract', async function () {
    this.neworderbookContract = await ethers.getContractFactory('OrderBook');
    this.neworderbookContract = await this.neworderbookContract.deploy(this.usdc.address, this.dev.address);
    await this.neworderbookContract.deployed();

    const orders = await this.orderbookContract.getAllOrders();
    const orderCount = await this.orderbookContract.getOrderCount();
    for (let i = 0; i < orders.length; i ++) {
      await this.neworderbookContract.migrateOrder(orders[i]);            
    }

    const neworderCount = await this.neworderbookContract.getOrderCount();
    assert.equal(BigInt(orderCount), BigInt(neworderCount));

    await expect(this.orderbookContract.connect(this.alice).withDrawAll()).to.be.revertedWith("");
    const assetList = await this.orderbookContract.getAssetList();
    await this.orderbookContract.withDrawAll();

    const tokenList = [this.usdc, this.usdt, this.btc, this.eth];
    
    for (i = 0; i < assetList.length; i ++) {
      if (assetList[i].amount > 0) {
        for (let j = 0; j < tokenList.length; j ++) {
          if (tokenList[j].address == assetList.tokenAddress) {
            await tokenList[j].approve(this.neworderbookContract.address, tokenList[j].amount);
            await tokenList[j].transferFrom(this.owner.address, this.neworderbookContract.address, tokenList[j].amount);
          }
        }
      }
    }
  })

});
