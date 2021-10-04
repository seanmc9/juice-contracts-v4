const AggregatorV3Interface = require('@chainlink/contracts/abi/v0.6/AggregatorV3Interface.json');

const addFeedFor = require('./add_feed_for');
const priceFor = require('./price_for');
const targetDecimals = require('./target_decimals');

module.exports = function () {
  before(async function () {
    // Deploy a mock of the price feed oracle contract.
    this.aggregatorV3Contract = await this.deployMockContractFn(
      AggregatorV3Interface.compilerOutput.abi,
    );

    this.contract = await this.deployContractFn('JBPrices');
  });

  describe('addFeedFor(...)', addFeedFor);
  describe('priceFor(...)', priceFor);
  describe('targetDecimals(...)', targetDecimals);
};