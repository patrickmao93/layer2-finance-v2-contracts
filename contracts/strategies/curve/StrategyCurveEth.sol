// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../../interfaces/IWETH.sol";
import "../interfaces/IStrategy.sol";
import "../interfaces/uniswap/IUniswapV2.sol";
import "../interfaces/curve/ICurveFi.sol";
import "../interfaces/curve/IGauge.sol";
import "../interfaces/curve/IMintr.sol";

contract StrategyCurveEth is IStrategy, Ownable {
    using SafeERC20 for IERC20;
    using Address for address;

    uint256 constant MAX_INT = 2**256 - 1;

    address public controller;

    // contract addresses
    address public pool; // swap pool
    address public gauge; // Curve gauge
    address public mintr; // Curve minter
    address public uniswap; // UniswapV2

    // supply token params
    uint8 public supplyTokenIndexInPool = 0; // ETH - 0, Other - 1

    // token addresses
    address public lpToken; // LP token
    address public crv; // CRV token
    address public weth; // WETH token

    // slippage tolerance settings
    uint256 public constant DENOMINATOR = 10000;
    uint256 public slippage = 500;

    uint256 public shares;

    constructor(
        address _controller,
        uint8 _supplyTokenIndexInPool,
        address _pool,
        address _lpToken,
        address _gauge,
        address _mintr,
        address _crv,
        address _weth,
        address _uniswap
    ) {
        controller = _controller;
        supplyTokenIndexInPool = _supplyTokenIndexInPool;
        pool = _pool;
        lpToken = _lpToken;
        gauge = _gauge;
        mintr = _mintr;
        crv = _crv;
        weth = _weth;
        uniswap = _uniswap;
    }

    modifier onlyController() {
        require(msg.sender == controller, "caller is not controller");
        _;
    }

    modifier onlyOwnerOrController() {
        require(msg.sender == owner() || msg.sender == controller, "caller is not owner or controller");
        _;
    }

    function getAssetAddress() external view override returns (address) {
        return weth;
    }

    function aggregateOrders(
        uint256 _buyAmount,
        uint256 _minSharesFromBuy,
        uint256 _sellShares,
        uint256 _minAmountFromSell
    ) external override onlyController returns (uint256, uint256) {
        require(msg.sender == controller, "Not controller");
        require(shares >= _sellShares, "not enough shares to sell");

        uint256 amountFromSell;
        uint256 sharesFromBuy;
        uint256 lpTokenPrice = ICurveFi(pool).get_virtual_price();
        uint256 sharePrice = syncPrice();

        if (assetAmount == 0 || shares == 0) {
            shares = _buyAmount;
            sharesFromBuy = _buyAmount;
        } else {
            amountFromSell = _sellShares * sharePrice;
            sharesFromBuy = _buyAmount / sharePrice;
        }

        if (amountFromSell < _buyAmount) {
            uint256 buyAmount = _buyAmount - amountFromSell;
            uint256 minLpTokenFromBuy = buyAmount * lpTokenPrice / 1e18 * (DENOMINATOR - slippage) / DENOMINATOR;
            uint256 actualLpTokenFromBuy = _buy(buyAmount, minLpTokenFromBuy);
            uint256 updatedLpTokenPrice = ICurveFi(pool).get_virtual_price();
            uint256 actualSharesFromBuy = actualLpTokenFromBuy * 1e18 / updatedLpTokenPrice / sharePrice;
            shares += actualSharesFromBuy;
            require(actualSharesFromBuy + _sellShares >= _minSharesFromBuy, "failed min shares from buy");
            emit Buy(buyAmount, actualSharesFromBuy);
            return (actualSharesFromBuy, 0);
        } else if (amountFromSell > _buyAmount) {
            uint256 sellShares = _sellShares - sharesFromBuy;
            uint256 sellLpTokens = sellShares * sharePrice * lpTokenPrice;
            uint256 minAmountFromSell = sellLpTokens * 1e18 / lpTokenPrice * (DENOMINATOR - slippage) / DENOMINATOR;
            uint256 actualAmountFromSell = _sell(sellLpTokens, minAmountFromSell);
            uint256 updatedSharePrice = syncPrice();
            shares -= actualAmountFromSell / updatedSharePrice;
            require(actualAmountFromSell + _buyAmount >= _minAmountFromSell, "failed min amount from sell");
            emit Sell(sellShares, actualAmountFromSell);
            return (0, actualAmountFromSell);
        }

        return (0, 0);
    }

    function _buy(uint256 _buyAmount, uint256 _minLpTokenFromBuy) private returns (uint256) {
        // pull fund from controller
        IERC20(weth).safeTransferFrom(msg.sender, address(this), _buyAmount);
        IWETH(weth).withdraw(_buyAmount);

        // add liquidity in pool
        uint256[2] memory amounts;
        amounts[supplyTokenIndexInPool] = _buyAmount;
        ICurveFi(pool).add_liquidity{value: _buyAmount}(amounts, _minLpTokenFromBuy);
        uint256 obtainedLpTokens = IERC20(lpToken).balanceOf(address(this));

        // deposit bought LP tokens to curve gauge to farm CRV
        IERC20(lpToken).safeIncreaseAllowance(gauge, obtainedLpTokens);
        IGauge(gauge).deposit(obtainedLpTokens);

        return obtainedLpTokens;
    }

    function _sell(uint256 _sellLpTokens, uint256 _minAmountFromSell) private {
        // pull shares from controller
        IERC20(weth).safeTransferFrom(msg.sender, address(this), _sellLpTokens);

        // remove liquidity from pool
        ICurveFi(pool).remove_liquidity_one_coin(_sellLpTokens, int8(supplyTokenIndexInPool), _minAmountFromSell);

        uint256 ethBalance = address(this).balance;

        // wrap ETH and send back to controller
        IWETH(weth).deposit{value: ethBalance}();
        IERC20(weth).safeTransfer(msg.sender, ethBalance);

        return ethBalance;
    }

    function syncPrice() external view override returns (uint256) {
        uint256 assetAmount = IERC20(lpToken).balanceOf(address(msg.sender)) / ICurveFi(pool).get_virtual_price();
        if (shares == 0) {
            if (assetAmount == 0) {
                return 1e18;
            }
            return MAX_INT;
        }
        return (assetAmount * 1e18) / shares;
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

            IUniswapV2(uniswap).swapExactTokensForETH(
                crvBalance,
                uint256(0),
                path,
                address(this),
                block.timestamp.add(1800)
            );

            // Re-invest supply token to obtain more lpToken
            uint256 obtainedAssetAmount = address(this).balance;
            uint256 minMintAmount = obtainedAssetAmount
             * 1e18)
            .div(ICurveFi(pool).get_virtual_price())
             * DENOMINATOR.sub(slippage))
            .div(DENOMINATOR);
            uint256[2] memory amounts;
            amounts[supplyTokenIndexInPool] = obtainedAssetAmount;
            ICurveFi(pool).add_liquidity{value: obtainedAssetAmount}(amounts, minMintAmount);

            // Stake lpToken in Gauge to farm more CRV
            uint256 obtainedLpToken = IERC20(lpToken).balanceOf(address(this));
            IERC20(lpToken).safeIncreaseAllowance(gauge, obtainedLpToken);
            IGauge(gauge).deposit(obtainedLpToken);

            // add newly obtained supply token amount to asset amount
            assetAmount = assetAmount.add(obtainedAssetAmount);
        }
    }

    function setController(address _controller) external onlyOwner {
        emit ControllerChanged(controller, _controller);
        controller = _controller;
    }
}
