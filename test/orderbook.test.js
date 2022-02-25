const { expect, assert } = require('chai');
const { BigNumber, parse } = require('ethers');
const { ethers } = require('hardhat');

const bigNum = num => (num + '0'.repeat(18))

describe('orderbook contract', function () {
  before (async function () {
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
    this.orderbookContract = await this.orderbookContract.deploy(this.usdc.address);
    await this.orderbookContract.deployed();
    console.log(`orderbook contract address is ${this.orderbookContract.address}`);
  })

  beforeEach(async function() {
    await this.usdc.approve(this.orderbookContract.address, bigNum(10000));
    await this.btc.approve(this.orderbookContract.address, bigNum(10000));
    await this.eth.approve(this.orderbookContract.address, bigNum(10000));
  })

  it ('place new ask order with btc token should be success', async function () {
    const [owner] = await ethers.getSigners();

    await this.orderbookContract.placeOrder(
      this.btc.address,
      0,  // ask
      bigNum(30), // 30 USDC
      bigNum(50), // 50 BTC 
      {from: owner.address}
    );

    const askOrderCount = await this.orderbookContract.getAskOrderCount();
    assert.equal(BigInt(askOrderCount), 1);
  })

  it ('place new bid order with eth token should be success', async function () {
    const [owner] = await ethers.getSigners();

    await this.orderbookContract.placeOrder(
      this.eth.address,
      1,  // bid
      bigNum(10), // 10 USDC
      bigNum(50), // 50 ETH
      {from: owner.address}
    );
    // console.log(await this.usdc.balanceOf(owner.address));

    const bidOrderCount = await this.orderbookContract.getBidOrderCount();
    assert.equal(BigInt(bidOrderCount), 1);
  })

  it ('place new bid order that matches to first ask order', async function () {
    const [owner] = await ethers.getSigners();

    // console.log(`BTC balance is ${await this.btc.balanceOf(owner.address)}`);
    // console.log(`USDC balance is ${await this.usdc.balanceOf(owner.address)}`);

    await this.orderbookContract.placeOrder(
      this.btc.address,
      1,  // bid
      bigNum(31), // 9 USDC
      bigNum(50), // 50 BTC
      {from: owner.address}
    );

    // console.log(`BTC balance is ${await this.btc.balanceOf(owner.address)}`);
    // console.log(`USDC balance is ${await this.usdc.balanceOf(owner.address)}`);
    
    // console.log(await this.usdc.balanceOf(owner.address));
  })

  
});