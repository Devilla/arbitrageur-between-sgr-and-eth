pragma solidity ^0.6.6;
pragma experimental ABIEncoderV2;

import { SafeMathOpenZeppelin } from "./libraries/SafeMathOpenZeppelin.sol";

import './FlashSwapHelper.sol';
import './uniswap-v2-periphery/interfaces/IUniswapV2Router02.sol';
import './sogur/interfaces/ISGRToken.sol';


/***
 * @notice - This contract that new version of ArbitrageurBtwSogurAndUniswap.sol
 **/
contract ArbitrageurBtwSogurAndUniswap {
    using SafeMathOpenZeppelin for uint;

    /// Arbitrage ID
    uint public currentArbitrageId;

    /// Mapping for saving bought amount and sold amount
    mapping (uint => mapping (address => uint)) ethAmountWhenBuySGR;   /// Key: arbitrageId -> userAddress -> ETH amount that was transferred for buying SGRToken
    mapping (uint => mapping (address => uint)) sgrAmountWhenSellSGR;  /// Key: arbitrageId -> userAddress -> SGR amount that was transferred for selling SGRToken

    FlashSwapHelper immutable flashSwapHelper;
    IUniswapV2Router02 immutable uniswapV2Router02;
    ISGRToken immutable SGRToken;

    address SGR_TOKEN;

    constructor(address payable _flashSwapHelper, address _uniswapV2Router02, address _sgrToken) public {
        flashSwapHelper = FlashSwapHelper(_flashSwapHelper);
        uniswapV2Router02 = IUniswapV2Router02(_uniswapV2Router02);
        SGRToken = ISGRToken(_sgrToken);

        SGR_TOKEN = _sgrToken;
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
    /// Workflow of arbitrage
    ///------------------------------------------------------------

    /***
     * @notice - Executor of flash swap for arbitrage profit (1: by using the flow of buying)
     **/
    function executeArbitrageByBuying(uint SGRAmount, address payable userAddress) public returns (bool) {
        /// Publish new arbitrage ID
        uint newArbitrageId = getNextArbitrageId();
        currentArbitrageId++;

        /// Buy SGR tokens on the SGR contract and Swap SGR tokens for ETH on the Uniswap
        buySGR(newArbitrageId);
        swapSGRForETH(SGRAmount);

        /// Transfer Ether that includes profit amount and initial amount into a user.
        transferETHIncludeProfitAmountAndInitialAmounToUser(userAddress); /// [Note]: If profit is happen, this method will be executed.
    }

    /***
     * @notice - Executor of flash swap for arbitrage profit (2: by using the flow of selling)
     **/
    function executeArbitrageBySelling(uint SGRAmount, address payable userAddress) public returns (bool) {
        /// Publish new arbitrage ID
        uint newArbitrageId = getNextArbitrageId();
        currentArbitrageId++;

        /// Sell SGR tokens on the SGR contract and Swap ETH for SGR tokens on the Uniswap
        sellSGR(newArbitrageId, SGRAmount);
        swapETHForSGR(SGRAmount);

        /// Transfer SGR tokens that includes profit amount and initial amount into a user.
        transferSGRIncludeProfitAmountAndInitialAmounToUser(userAddress);
    }


    ///------------------------------------------------------------
    /// Parts of workflow of arbitrage (1st part)
    ///------------------------------------------------------------

    /***
     * @notice - Buying SGR from Sögur's smart contract (by sending ETH to it)
     **/
    function buySGR(uint arbitrageId) public payable returns (bool) {
        /// At the 1st, ETH should be transferred from a user's wallet to this contract

        /// At the 2nd, operations below are executed.
        SGRToken.exchange();  /// Exchange ETH for SGR.
        ethAmountWhenBuySGR[arbitrageId][msg.sender] = msg.value;  /// [Note]: Save the ETH amount that was transferred for buying SGRToken 
    }

    /***
     * @notice - Swap the received SGR back to ETH on Uniswap
     **/
    function swapSGRForETH(uint SGRAmount) public returns (bool) {
        flashSwapHelper.swapSGRForETH(SGRAmount);
    }
    
    /***
     * @notice - Selling SGR for ETH from Sögur's smart contract
     * @dev - Only specified the contract address of SGRToken.sol as a "to" address in transferFrom() method 
     **/
    function sellSGR(uint arbitrageId, uint SGRAmount) public returns (bool) {
        /// At the 1st, SGR tokens should be transferred from a user's wallet to this contract by using transfer() method. 

        /// At the 2nd, operation below is executed
        SGRToken.transferFrom(msg.sender, address(this), SGRAmount); /// [Note]: SGR exchanged with ETH via transferFrom() method
        sgrAmountWhenSellSGR[arbitrageId][msg.sender] = SGRAmount;   /// [Note]: Save the SGR amount that was transferred for selling SGRToken
    }

    /***
     * @notice - Swap the received ETH back to SGR on Uniswap (ETH - SGR)
     **/    
    function swapETHForSGR(uint SGRAmount) public returns (bool) {
        flashSwapHelper.swapETHForSGR(SGRAmount);
        //flashSwapHelper.uniswapV2Call(sender, amount0, amount1, data);
    }


    ///------------------------------------------------------------
    /// Parts of workflow of arbitrage (2nd part)
    ///------------------------------------------------------------

    /***
     * @notice - Transfer ETH that includes profit amount and initial amount into a user.
     **/
    function transferETHIncludeProfitAmountAndInitialAmounToUser(address payable userAddress) public returns (bool) {
        uint ETHBalanceOfContract = address(this).balance;
        userAddress.transfer(ETHBalanceOfContract);  /// Transfer ETH from this contract to userAddress's wallet
    }

    /***
     * @notice - Transfer SGR tokens that includes profit amount and initial amount into a user.
     **/
    function transferSGRIncludeProfitAmountAndInitialAmounToUser(address userAddress) public returns (bool) {
        uint SGRBalanceOfContract = SGRToken.balanceOf(address(this));
        SGRToken.transfer(userAddress, SGRBalanceOfContract);  /// Transfer SGR from this contract to userAddress's wallet        
    }



    ///------------------------------------------------------------
    /// Internal functions
    ///------------------------------------------------------------



    ///------------------------------------------------------------
    /// Getter functions
    ///------------------------------------------------------------

    function getEthAmountWhenBuySGR(uint arbitrageId, address userAddress) public view returns (uint _ethAmountWhenBuySGR) {
        return ethAmountWhenBuySGR[arbitrageId][userAddress];
    }    

    function getSgrAmountWhenSellSGR(uint arbitrageId, address userAddress) public view returns (uint _sgrAmountWhenSellSGR) {
        return sgrAmountWhenSellSGR[arbitrageId][userAddress];
    }


    ///------------------------------------------------------------
    /// Private functions
    ///------------------------------------------------------------

    function getNextArbitrageId() private view returns (uint nextArbitrageId) {
        return currentArbitrageId.add(1);
    }


}
