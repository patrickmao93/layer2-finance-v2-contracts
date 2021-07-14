// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../../interfaces/IWETH.sol";
import "../interfaces/uniswap/IUniswapV2.sol";
import "../interfaces/curve/ICurveFi.sol";
import "../interfaces/curve/IGauge.sol";
import "../interfaces/curve/IMintr.sol";
import "../AbstractStrategy.sol";

contract StrategyCurve3Pool is AbstractStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    uint256 public constant SLIPPAGE_NUMERATOR = 500;
    uint256 public constant SLIPPAGE_DENOMINATOR = 10000;

    address public pool;
    address public gauge;
    address public mintr;
    address public uniswap;
    address public crv;
    address public weth;
    address public lpToken;
    uint8 public supplyTokenIndexInPool = 0;

    constructor(
        address _controller,
        address _lpToken,
        address _supplyToken,
        uint8 _supplyTokenIndexInPool,
        address _pool,
        address _gauge,
        address _mintr,
        address _crv,
        address _weth,
        address _uniswap
    ) AbstractStrategy(_controller, _supplyToken) {
        pool = _pool;
        gauge = _gauge;
        mintr = _mintr;
        crv = _crv;
        weth = _weth;
        uniswap = _uniswap;
        lpToken = _lpToken;
        supplyTokenIndexInPool = _supplyTokenIndexInPool;
    }

    function getAssetAmount() public view override returns (uint256) {
        return IERC20(lpToken).balanceOf(address(msg.sender)) / ICurveFi(pool).get_virtual_price() / PRICE_DECIMALS;
    }

    function buy(uint256 _buyAmount) internal override returns (uint256) {
        // pull fund from controller
        IERC20(supplyToken).safeTransferFrom(msg.sender, address(this), _buyAmount);

        // add liquidity in pool
        uint256[3] memory amounts;
        amounts[supplyTokenIndexInPool] = _buyAmount;
        uint256 minAmountFromBuy = (_buyAmount * SLIPPAGE_NUMERATOR) / SLIPPAGE_DENOMINATOR;
        ICurveFi(pool).add_liquidity(amounts, minAmountFromBuy);
        uint256 obtainedLpTokens = IERC20(lpToken).balanceOf(address(this));

        // deposit bought LP tokens to curve gauge to farm CRV
        IERC20(lpToken).safeIncreaseAllowance(gauge, obtainedLpTokens);
        IGauge(gauge).deposit(obtainedLpTokens);

        return obtainedLpTokens;
    }

    function sell(uint256 _sellAmount) internal override returns (uint256) {
        uint256 sellLpTokens = (_sellAmount * ICurveFi(pool).get_virtual_price()) / PRICE_DECIMALS;
        // unstake from needed lpTokens for sell from gauge
        IGauge(gauge).withdraw(sellLpTokens);

        // remove liquidity from pool
        uint256 minAmountFromSell = (_sellAmount * SLIPPAGE_NUMERATOR) / SLIPPAGE_DENOMINATOR;
        ICurveFi(pool).remove_liquidity_one_coin(sellLpTokens, int8(supplyTokenIndexInPool), minAmountFromSell);
        uint256 obtainedSupplyToken = IERC20(supplyToken).balanceOf(address(this));
        IERC20(supplyToken).safeTransfer(msg.sender, obtainedSupplyToken);

        return obtainedSupplyToken;
    }

    function harvest() external override onlyOwnerOrController {
        IMintr(mintr).mint(gauge);
        uint256 crvBalance = IERC20(crv).balanceOf(address(this));

        if (crvBalance > 0) {
            // Sell CRV for more supply token
            IERC20(crv).safeIncreaseAllowance(uniswap, crvBalance);

            address[] memory path = new address[](2);
            path[0] = crv;
            path[1] = weth;
            path[2] = supplyToken;

            IUniswapV2(uniswap).swapExactTokensForETH(
                crvBalance,
                uint256(0),
                path,
                address(this),
                block.timestamp + 1800
            );

            // Re-invest supply token to obtain more lpToken
            uint256 obtainedAssetAmount = address(this).balance;
            uint256 minMintAmount = (((obtainedAssetAmount * PRICE_DECIMALS) / ICurveFi(pool).get_virtual_price()) *
                SLIPPAGE_NUMERATOR) / SLIPPAGE_DENOMINATOR;
            uint256[3] memory amounts;
            amounts[supplyTokenIndexInPool] = obtainedAssetAmount;
            ICurveFi(pool).add_liquidity(amounts, minMintAmount);

            // Stake lpToken in Gauge to farm more CRV
            uint256 obtainedLpToken = IERC20(lpToken).balanceOf(address(this));
            IERC20(lpToken).safeIncreaseAllowance(gauge, obtainedLpToken);
            IGauge(gauge).deposit(obtainedLpToken);
        }
    }
}
