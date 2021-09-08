// SPDX-License-Identifier: MIT
pragma solidity 0.5.6;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "./interfaces/IOracle.sol";
import "./interfaces/IKlayswapFactory.sol";

import "./BBFundStorage.sol";
import "./BBFund.sol";

contract BBFundImpl is BBFundStorage {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========== EVENTS ========== */
    event Initialized(address indexed executor, uint256 at);
    event SwapToken(address inputToken, address outputToken, uint256 amount);
    event ExecuteTransaction(address indexed target, uint256 value, string signature, bytes data);

    /* =================== Admin Functions =================== */
    function _become(BBFund fund) public {
        require(msg.sender == fund.admin(), "only fund admin can change brains");
        fund._acceptImplementation();
    }

    /* ========== Modifiers =============== */
    modifier onlyAdmin() {
        require(msg.sender == admin, "BBFundImpl: only admin can");
        _;
    }

    modifier onlyStrategist() {
        require(msg.sender == strategist || msg.sender == admin, "BBFundImpl: only strategist or admin can");
        _;
    }

    modifier checkPublicAllow() {
        require(publicAllowed || msg.sender == admin, "!admin nor !publicAllowed");
        _;
    }

    /* ========== GOVERNANCE ========== */
    function initialize(
        address _jun,
        address _junb,
        address _juns,
        address _usdt,
        address _oracle,
        address _klayswapFactory,
        address _treasury
    ) public onlyAdmin {
        require(initialized == false, "already initiallized");

        jun = _jun;
        junb = _junb;
        juns = _juns;
        usdt = _usdt;
        oracle = _oracle;
        klayswapFactory = _klayswapFactory;
        treasury = _treasury;
        junPriceToSell = 1.05 ether;
        junPriceToBuy = 0.99 ether;
        publicAllowed = false;
        strategist = msg.sender;

        maxAmountToTrade[jun] = 10000 ether;
        maxAmountToTrade[usdt] = 10000 ether;
        maxAmountToTrade[address(0)] = 10000 ether;

        initialized = true;

        emit Initialized(msg.sender, block.number);
    }

    function setStrategist(address _strategist) external onlyAdmin {
        strategist = _strategist;
    }

    function setOracle(address _oracle) external onlyAdmin {
        oracle = _oracle;
    }

    function setPublicAllowed(bool _publicAllowed) external onlyStrategist {
        publicAllowed = _publicAllowed;
    }

    function setJUNPriceToSell(uint256 _priceToSell) external onlyStrategist {
        require(_priceToSell > 1.0 ether, "out of range");
        junPriceToSell = _priceToSell;
    }

    function setJUNPriceToBuy(uint256 _priceToBuy) external onlyStrategist {
        require(_priceToBuy < 1.0 ether, "out of range");
        junPriceToBuy = _priceToBuy;
    }

    function setMaxAmountToTrade(address _token, uint256 _maxAmount) external onlyStrategist {
        require(_maxAmount > 0 ether && _maxAmount < 100000 ether, "out of range");
        maxAmountToTrade[_token] = _maxAmount;
    }

    function setTreasuryAllowance(uint256 _amount) external onlyAdmin {
        IERC20(jun).safeIncreaseAllowance(address(treasury), _amount);
    }

    /* ========== VIEW FUNCTIONS ========== */
    function getJUNPrice() public view returns (uint256) {
        return IOracle(oracle).consult(jun, 1e18);
    }

    function getJUNUpdatedPrice() public view returns (uint256) {
        return IOracle(oracle).twap(jun, 1e18);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */
    function rebalance() public checkPublicAllow {
    }

    function forceSell(address _buyingToken, uint256 _amount) external onlyStrategist {
        require(getJUNUpdatedPrice() >= junPriceToSell, "price is too low to sell");
        _swapToken(jun, _buyingToken, _amount);
    }

    function forceBuy(address _sellingToken, uint256 _amount) external onlyStrategist {
        require(getJUNUpdatedPrice() <= junPriceToBuy, "price is too high to buy");
        _swapToken(_sellingToken, jun, _amount);
    }

    function _swapToken(address _inputToken, address _outputToken, uint256 _amount) internal {
        if (_amount == 0) return;
        uint256 _maxAmount = maxAmountToTrade[_inputToken];

        if (_maxAmount > 0 && _maxAmount < _amount) {
            _amount = _maxAmount;
        }

        address[] memory _path;
        IERC20(_inputToken).safeIncreaseAllowance(address(klayswapFactory), _amount);
        IKlayswapFactory(klayswapFactory).exchangeKctPos(_inputToken, _amount, _outputToken, 1, _path);
    }
}
