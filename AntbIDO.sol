// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;

import '../interfaces/IERC20.sol';
import '../interfaces/IUniswapV2Router02.sol';
import '../interfaces/IUniswapV2Pair.sol';
import '../types/Ownable.sol';
import '../types/ERC20Detailed.sol';
import '../libraries/SafeMath.sol';
import '../libraries/SafeERC20.sol';

contract AntbIDO is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public ANTB;
    address public maticANTBLP;
    address public router;

    uint256 public initialTotalAmount;
    uint256 public totalAmount = 0;
    uint256 public softCap;
    uint256 public saleRate;
    uint256 public minPurchaseAmount;
    uint256 public maxPurchaseAmount;
    uint256 public totalWhiteListed;
    uint256 public startOfSale;
    uint256 public endOfSale;

    bool public initialized;
    bool public whiteListEnabled;
    bool public cancelled;
    bool public finalized;

    mapping(address => bool) public whiteListed;

    address[] buyers;
    mapping(address => uint256) public purchasedAmounts;

    address treasury;

    constructor(
        address _ANTB,
        address _treasury,
        address _router,
        address _maticANTBLP
    ) {
        require(_ANTB != address(0));
        require(_treasury != address(0));
        require(_maticANTBLP != address(0));

        ANTB = _ANTB;
        treasury = _treasury;
        maticANTBLP = _maticANTBLP;
        router = _router;
        cancelled = false;
        finalized = false;
        initialized = false;
    }

    function saleStarted() public view returns (bool) {
        return initialized && startOfSale <= block.timestamp;
    }

    function whiteListBuyers(address[] memory _buyers) external onlyOwner returns (bool) {
        require(saleStarted() == false, 'Already started');

        totalWhiteListed = totalWhiteListed.add(_buyers.length);

        for (uint256 i; i < _buyers.length; i++) {
            whiteListed[_buyers[i]] = true;
        }

        return true;
    }

    function initialize(
        uint256 _totalAmountToSell, // in 1e5
        uint256 _softCap, // in 1e18
        uint256 _saleRate, // in 1e5
        uint256 _minPurchaseAmount, // in 1e18
        uint256 _maxPurchaseAmount, // in 1e18
        uint256 _saleLength, // timestamp
        uint256 _startOfSale, // timestamp
        bool _enableWhiteList
    ) external onlyOwner returns (bool) {
        require(initialized == false, 'Already initialized');
        initialized = true;
        whiteListEnabled = _enableWhiteList;
        initialTotalAmount = _totalAmountToSell;
        totalAmount = _totalAmountToSell;
        softCap = _softCap;
        saleRate = _saleRate;
        minPurchaseAmount = _minPurchaseAmount;
        maxPurchaseAmount = _maxPurchaseAmount;
        startOfSale = _startOfSale;
        endOfSale = _startOfSale.add(_saleLength);

        return true;
    }

    function purchaseANTB() external payable returns (bool) {
        require(saleStarted() == true, 'Not started');
        require(!whiteListEnabled || whiteListed[msg.sender] == true, 'Not whitelisted');
        uint256 _amountMATIC = msg.value;
        uint256 totalAmountBought = purchasedAmounts[msg.sender] > 0
            ? _amountMATIC.add(_calculateMaticQuote(purchasedAmounts[msg.sender]))
            : _amountMATIC;
        require(totalAmountBought >= minPurchaseAmount, 'Less than minimum purchase amount');
        require(totalAmountBought <= maxPurchaseAmount, 'More than maximum purchase amount');
        require(_calculateSaleQuote(totalAmountBought) <= totalAmount, 'No tokens left');

        uint256 _purchaseAmount = _calculateSaleQuote(_amountMATIC);

        totalAmount = totalAmount.sub(_purchaseAmount);

        if (purchasedAmounts[msg.sender] == 0) {
            buyers.push(msg.sender);
        }

        purchasedAmounts[msg.sender] = _purchaseAmount;

        return true;
    }

    function enableWhiteList() external onlyOwner {
        whiteListEnabled = true;
    }

    function disableWhiteList() external onlyOwner {
        whiteListEnabled = false;
    }

    function _calculateSaleQuote(uint256 paymentAmount_) internal view returns (uint256) {
        return paymentAmount_.div(1e18).mul(saleRate);
    }

    function _calculateMaticQuote(uint256 paymentAmount_) internal view returns (uint256) {
        return paymentAmount_.div(saleRate).mul(1e18);
    }

    /// @dev Only Emergency Use
    /// cancel the IDO and return the funds to all buyer
    function cancel() external onlyOwner {
        cancelled = true;
        startOfSale = 99999999999;
    }

    function withdraw() external {
        require(cancelled, 'ido is not cancelled');
        require(purchasedAmounts[msg.sender] > 0, 'not purchased');

        uint256 amountToSend = _calculateMaticQuote(purchasedAmounts[msg.sender]);
        purchasedAmounts[msg.sender] = 0;
        (bool sent, ) = payable(msg.sender).call{value: amountToSend}('');
        require(sent, 'Failed to send Matic');
    }

    function claim(address _recipient) public {
        require(finalized, 'only can claim after finalized');
        require(purchasedAmounts[_recipient] > 0, 'not purchased');

        IERC20(ANTB).transfer(_recipient, purchasedAmounts[_recipient]);

        purchasedAmounts[_recipient] = 0;
    }

    function finalize() external onlyOwner {
        uint256 totalPurchased = initialTotalAmount.sub(totalAmount);
        require(_calculateMaticQuote(totalPurchased) >= softCap, 'softCap not reached');

        uint256 maticTosend = totalPurchased.div(2).div(saleRate).mul(1e18);
        uint256 antbTosend = totalPurchased.div(2);

        IERC20(ANTB).approve(router, antbTosend);
        IUniswapV2Router02(router).addLiquidityETH{value: maticTosend}(
            ANTB,
            antbTosend,
            antbTosend,
            maticTosend,
            treasury,
            block.timestamp + 20000
        );

        uint256 antbBalance = IERC20(ANTB).balanceOf(address(this));
        uint256 maticBalance = address(this).balance;
        IERC20(ANTB).transfer(treasury, antbBalance);
        (bool sentTreasury, ) = payable(treasury).call{value: maticBalance}('');
        require(sentTreasury, 'Failed to send Matic to treasury');

        finalized = true;
    }
}
