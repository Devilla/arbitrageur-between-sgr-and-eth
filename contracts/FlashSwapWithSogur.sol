pragma solidity ^0.6.6;
pragma experimental ABIEncoderV2;

import './uniswap-v2-core/interfaces/IUniswapV2Callee.sol';
import './uniswap-v2-core/interfaces/IUniswapV2Pair.sol';
import './uniswap-v2-periphery/libraries/UniswapV2Library.sol';
import './uniswap-v2-periphery/interfaces/V1/IUniswapV1Factory.sol';
import './uniswap-v2-periphery/interfaces/V1/IUniswapV1Exchange.sol';
import './uniswap-v2-periphery/interfaces/IUniswapV2Router01.sol';
import './uniswap-v2-periphery/interfaces/IUniswapV2Router02.sol';
import './uniswap-v2-periphery/interfaces/IERC20.sol';

import './sogur/interfaces/ISGRToken.sol';

/***
 * @notice - This contract that ...
 **/
contract FlashSwapWithSogur is IUniswapV2Callee {
    IUniswapV2Pair immutable uniswapV2Pair;
    IUniswapV2Router02 immutable uniswapV2Router02;
    IUniswapV1Factory immutable factoryV1;
    address immutable factory;
    ISGRToken immutable SGRToken;

    constructor(address _uniswapV2Pair, address _uniswapV2Router02, address _factory, address _factoryV1, address router, address _sgrToken) public {
        uniswapV2Pair = IUniswapV2Pair(_uniswapV2Pair);
        uniswapV2Router02 = IUniswapV2Router02(_uniswapV2Router02);
        factoryV1 = IUniswapV1Factory(_factoryV1);
        factory = _factory;
        SGRToken = ISGRToken(_sgrToken);
    }


    ///------------------------------------------------------------
    /// In advance, add a pair (SGR - ETH) liquidity into Uniswap Pool (and create factory contract address)
    ///------------------------------------------------------------

    /***
     * @notice - Add a pair (SGR - ETH) liquidity into Uniswap Pool (and create factory contract address)
     **/
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) public returns (bool) {
        uniswapV2Router02.addLiquidityETH(token, amountTokenDesired, amountTokenMin, amountETHMin, to, deadline);
    }
    

    ///------------------------------------------------------------
    /// Workflow of Flash Swap
    ///------------------------------------------------------------

    /***
     * @notice - Executor of flash swap for arbitrage profit (1: by using the flow of buying)
     **/
    function arbitrageByBuyingExecutor() public returns (bool) {
        buySGR();
        swapSGRForETH();
    }

    /***
     * @notice - Executor of flash swap for arbitrage profit (2: by using the flow of selling)
     **/
    function arbitrageBySellingExecutor(address sender, uint amount0, uint amount1, bytes memory data, address pairAddress0, address pairAddress1) public returns (bool) {
        sellSGR();
        swapETHForSGR(sender, amount0, amount1, data, pairAddress0, pairAddress1);
    }


    ///------------------------------------------------------------
    /// Parts of workflow of Flash Swap
    ///------------------------------------------------------------

    /***
     * @notice - Buying SGR from Sögur's smart contract (by sending ETH to it)
     **/
    function buySGR() public returns (bool) {
        SGRToken.exchange();
    }

    /***
     * @notice - Swap the received SGR back to ETH on Uniswap
     **/    
    function swapSGRForETH() public returns (bool) {

    }
    
    /***
     * @notice - Selling SGR for ETH from Sögur's smart contract
     **/
    function sellSGR() public returns (bool) {
        SGRToken.withdraw();  /// [ToDo]: withdraw method is for that ETH is transferred
    }

    /***
     * @notice - Swap the received ETH back to SGR on Uniswap (ETH - SGR)
     **/    
    function swapETHForSGR(address sender, uint amount0, uint amount1, bytes memory data, address pairAddress0, address pairAddress1) public returns (bool) {
        address[] memory path = new address[](2);
        uint amountToken;  /// [Note]: This is SGR token
        uint amountETH;
        { // scope for token{0,1}, avoids stack too deep errors
        address token0 = IUniswapV2Pair(pairAddress0).token0();
        address token1 = IUniswapV2Pair(pairAddress1).token1();
        assert(msg.sender == UniswapV2Library.pairFor(factory, token0, token1)); // ensure that msg.sender is actually a V2 pair
        assert(amount0 == 0 || amount1 == 0); // this strategy is unidirectional
        path[0] = amount0 == 0 ? token0 : token1;
        path[1] = amount0 == 0 ? token1 : token0;
        amountToken = token0 == address(SGRToken) ? amount1 : amount0;
        amountETH = token0 == address(SGRToken) ? amount0 : amount1;
        }

        assert(path[0] == address(SGRToken) || path[1] == address(SGRToken)); // this strategy only works with a V2 SGRToken pair
        IERC20 token = IERC20(path[0] == address(SGRToken) ? path[1] : path[0]);
        IUniswapV1Exchange exchangeV1 = IUniswapV1Exchange(factoryV1.getExchange(address(token))); // get V1 exchange

        if (amountToken > 0) {
            (uint minETH) = abi.decode(data, (uint)); // slippage parameter for V1, passed in by caller
            token.approve(address(exchangeV1), amountToken);
            uint amountReceived = exchangeV1.tokenToEthSwapInput(amountToken, minETH, uint(-1));
            uint amountRequired = UniswapV2Library.getAmountsIn(factory, amountToken, path)[0];
            assert(amountReceived > amountRequired); // fail if we didn't get enough ETH back to repay our flash loan
            SGRToken.deposit{value: amountRequired}();
            assert(SGRToken.transfer(msg.sender, amountRequired)); // return SGRToken to V2 pair
            (bool success,) = sender.call{value: amountReceived - amountRequired}(new bytes(0)); // keep the rest! (ETH)
            assert(success);
        } else {
            (uint minTokens) = abi.decode(data, (uint)); // slippage parameter for V1, passed in by caller
            SGRToken.withdraw();
            uint amountReceived = exchangeV1.ethToTokenSwapInput{value: amountETH}(minTokens, uint(-1));
            uint amountRequired = UniswapV2Library.getAmountsIn(factory, amountETH, path)[0];
            assert(amountReceived > amountRequired); // fail if we didn't get enough tokens back to repay our flash loan
            assert(token.transfer(msg.sender, amountRequired)); // return tokens to V2 pair
            assert(token.transfer(sender, amountReceived - amountRequired)); // keep the rest! (tokens)
        }
    }    


    ///------------------------------------------------------------
    /// Flash Swap (that reference ExampleFlashSwap.sol)
    ///------------------------------------------------------------

    /***
     * @notice - Swap SGRToken for ETH (Swap between SGRToken - ETH)
     **/
    // needs to accept ETH from any V1 exchange and SGRToken. ideally this could be enforced, as in the router,
    // but it's not possible because it requires a call to the v1 factory, which takes too much gas
    receive() external payable {}

    // gets tokens/SGRToken via a V2 flash swap, swaps for the ETH/tokens on V1, repays V2, and keeps the rest!
    function uniswapV2Call(address sender, uint amount0, uint amount1, bytes calldata data) external override {
        address[] memory path = new address[](2);
        uint amountToken;
        uint amountETH;
        { // scope for token{0,1}, avoids stack too deep errors
        address token0 = IUniswapV2Pair(msg.sender).token0();
        address token1 = IUniswapV2Pair(msg.sender).token1();
        assert(msg.sender == UniswapV2Library.pairFor(factory, token0, token1)); // ensure that msg.sender is actually a V2 pair
        assert(amount0 == 0 || amount1 == 0); // this strategy is unidirectional
        path[0] = amount0 == 0 ? token0 : token1;
        path[1] = amount0 == 0 ? token1 : token0;
        amountToken = token0 == address(SGRToken) ? amount1 : amount0;
        amountETH = token0 == address(SGRToken) ? amount0 : amount1;
        }

        assert(path[0] == address(SGRToken) || path[1] == address(SGRToken)); // this strategy only works with a V2 SGRToken pair
        IERC20 token = IERC20(path[0] == address(SGRToken) ? path[1] : path[0]);
        IUniswapV1Exchange exchangeV1 = IUniswapV1Exchange(factoryV1.getExchange(address(token))); // get V1 exchange

        if (amountToken > 0) {
            (uint minETH) = abi.decode(data, (uint)); // slippage parameter for V1, passed in by caller
            token.approve(address(exchangeV1), amountToken);
            uint amountReceived = exchangeV1.tokenToEthSwapInput(amountToken, minETH, uint(-1));
            uint amountRequired = UniswapV2Library.getAmountsIn(factory, amountToken, path)[0];
            assert(amountReceived > amountRequired); // fail if we didn't get enough ETH back to repay our flash loan
            SGRToken.deposit{value: amountRequired}();
            assert(SGRToken.transfer(msg.sender, amountRequired)); // return SGRToken to V2 pair
            (bool success,) = sender.call{value: amountReceived - amountRequired}(new bytes(0)); // keep the rest! (ETH)
            assert(success);
        } else {
            (uint minTokens) = abi.decode(data, (uint)); // slippage parameter for V1, passed in by caller
            SGRToken.withdraw();
            uint amountReceived = exchangeV1.ethToTokenSwapInput{value: amountETH}(minTokens, uint(-1));
            uint amountRequired = UniswapV2Library.getAmountsIn(factory, amountETH, path)[0];
            assert(amountReceived > amountRequired); // fail if we didn't get enough tokens back to repay our flash loan
            assert(token.transfer(msg.sender, amountRequired)); // return tokens to V2 pair
            assert(token.transfer(sender, amountReceived - amountRequired)); // keep the rest! (tokens)
        }
    }


    ///------------------------------------------------------------
    /// Internal functions
    ///------------------------------------------------------------



    ///------------------------------------------------------------
    /// Getter functions
    ///------------------------------------------------------------



    ///------------------------------------------------------------
    /// Private functions
    ///------------------------------------------------------------


}
