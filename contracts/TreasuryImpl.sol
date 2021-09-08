// SPDX-License-Identifier: MIT
pragma solidity 0.5.6;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./lib/Babylonian.sol";
import "./owner/Operator.sol";
import "./interfaces/IJUNAsset.sol";
import "./interfaces/IOracle.sol";
import "./interfaces/IBoardroom.sol";

import "./TreasuryStorage.sol";
import "./TreasuryUni.sol";
import "./interfaces/ITreasury.sol";

/**
 * @title JUN Protocol Treasury contract
 * @notice Monetary policy logic to adjust supplies of JUN
 */
contract TreasuryImpl is TreasuryStorage {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* =================== Events =================== */

    event Initialized(address indexed executor, uint256 at);
    event RedeemedJUNB(address indexed from, uint256 junAmount, uint256 junbAmount);
    event BoughtJUNB(address indexed from, uint256 junAmount, uint256 junbAmount);
    event TreasuryFunded(uint256 timestamp, uint256 seigniorage);
    event BoardroomFunded(uint256 timestamp, uint256 seigniorage);
    event TeamFundFunded(uint256 timestamp, uint256 seigniorage);
    event BuyBackFunded(uint256 timestamp, uint256 seigniorage);
    event BuyBackBurnedJUN(uint256 timestamp, uint256 junAmount);

    /* =================== Admin Functions =================== */
    function _become(TreasuryUni uni) public {
        require(msg.sender == uni.admin(), "admin can change brains");
        uni._acceptImplementation();
    }

    /* =================== Modifier =================== */
    function checkSameOriginReentranted() internal view returns (bool) {
        return _status[block.number][tx.origin];
    }

    function checkSameSenderReentranted() internal view returns (bool) {
        return _status[block.number][msg.sender];
    }

    modifier onlyOneBlock() {
        require(!checkSameOriginReentranted(), "one block, one function");
        require(!checkSameSenderReentranted(), "one block, one function");

        _;

        _status[block.number][tx.origin] = true;
        _status[block.number][msg.sender] = true;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "only admin can");
        _;
    }
    modifier checkCondition {
        require(now >= startTime, "not started yet");
        _;
    }

    modifier checkEpoch {
        require(now >= nextRoundPoint(), "not opened yet");
        _;
        round = round.add(1);
        roundSupplyContractionLeft = (getJUNPrice() >= junPriceOne) ? 0 : IERC20(jun).totalSupply().mul(maxSupplyContractionPercent).div(10000);
    }

    modifier checkOperator {
        require(
            Operator(jun).operator() == address(this) &&
                Operator(junb).operator() == address(this) &&
                Operator(juns).operator() == address(this) &&
                Operator(boardroom).operator() == address(this),
            "need more permission"
        );
        _;
    }

    /* ========== VIEW FUNCTIONS ========== */

    function getStartTime() public view returns (uint256) {
        return startTime;
    }

    // round
    function nextRoundPoint() public view returns (uint256) {
        return startTime.add(round.mul(PERIOD));
    }

    // oracle
    function getJUNPrice() public view returns (uint256) {
        return IOracle(junOracle).consult(jun, 1e18);
    }

    function getJUNUpdatedPrice() public view returns (uint256) {
        return IOracle(junOracle).twap(jun, 1e18);
    }

    // budget
    function getReserve() public view returns (uint256) {
        return seigniorageSaved;
    }

    function getBurnableJUNLeft() public view returns (uint256 _burnableLeft) {
        uint256  _junPrice = getJUNPrice();
        if (_junPrice < junPriceOne) {
            uint256 _junSupply = IERC20(jun).totalSupply();
            uint256 _junbMaxSupply = _junSupply.mul(maxDeptRatioPercent).div(10000);
            uint256 _junbSupply = IERC20(junb).totalSupply();
            if (_junbMaxSupply > _junbSupply) {
                uint256 _maxMintableJUNB = _junbMaxSupply.sub(_junbSupply);
                uint256 _maxBurnableJUN = _maxMintableJUNB.mul(_junPrice).div(1e18);
                _burnableLeft = Math.min(roundSupplyContractionLeft, _maxBurnableJUN);
            }
        }
    }

    function getRedeemableJUNB() public view returns (uint256 _redeemableJUNB) {
        uint256  _junPrice = getJUNPrice();
        if (_junPrice > junPriceOne) {
            uint256 _totalJUN = IERC20(jun).balanceOf(address(this));
            uint256 _rate = getJUNBPremiumRate();
            if (_rate > 0) {
                _redeemableJUNB = _totalJUN.mul(1e18).div(_rate);
            }
        }
    }

    function getJUNBDiscountRate() public view returns (uint256 _rate) {
        uint256 _junPrice = getJUNPrice();
        if (_junPrice < junPriceOne) {
             _rate = junPriceOne;
        }
    }

    function getJUNBPremiumRate() public view returns (uint256 _rate) {
        uint256 _junPrice = getJUNPrice();
        if (_junPrice >= junPriceOne) {
            _rate = junPriceOne;
        }
    }

    /* ========== GOVERNANCE ========== */
    constructor() public {
        admin = msg.sender;
    }

    function initialize (
        address _jun,
        address _junb,
        address _juns,
        uint256 _startTime
    ) external onlyAdmin {
        require(initialized == false, "already initiallized");

        jun = _jun;
        junb = _junb;
        juns = _juns;
        startTime = _startTime;

        junPriceOne = 10**18;

        bootstrapRounds = 21; // 1 weeks (8 * 21 / 24)
        bootstrapSupplyExpansionPercent = 300; // 3%
        maxSupplyExpansionPercent = 300; // Upto 3% supply for expansion
        maxSupplyExpansionPercentInDebtPhase = 300; // Upto 3% supply for expansion in debt phase (to pay debt faster)
        junbDepletionFloorPercent = 10000; // 100% of JUNB supply for depletion floor
        seigniorageExpansionFloorPercent = 3500; // At least 35% of expansion reserved for boardroom
        seigniorageExpansionRate = 3000; // (TWAP - 1) * 100% * 30%
        maxSupplyContractionPercent = 300; // Upto 3.0% supply for contraction (to burn JUN and mint JUNB)
        maxDeptRatioPercent = 3500; // Upto 35% supply of JUNB to purchase

        allocateSeigniorageSalary = 50 ether;
        redeemPenaltyRate = 0.9 ether; // 0.9, 10% penalty
        mintingFactorForPayingDebt = 10000; // 100%

        teamFund = msg.sender;
        teamFundSharedPercent = 1000; // 10%

        buyBackFund = msg.sender;
        buyBackFundExpansionRate = 1000; // 10%
        maxBuyBackFundExpansion = 300; // 3%

        // set seigniorageSaved to it's balance
        seigniorageSaved = IERC20(jun).balanceOf(address(this));

        initialized = true;

        emit Initialized(msg.sender, block.number);
    }

    function setBoardroom(address _boardroom) external onlyAdmin {
        require(_boardroom != address(0), "zero");
        boardroom = _boardroom;
    }

    function setJUNOracle(address _oracle) external onlyAdmin {
        require(_oracle != address(0), "zero");
        junOracle = _oracle;
    }

    function setRound(uint256 _round) external onlyAdmin {
        round = _round;
    }
    
    function setMaxSupplyExpansionPercents(uint256 _maxSupplyExpansionPercent, uint256 _maxSupplyExpansionPercentInDebtPhase) external onlyAdmin {
        require(_maxSupplyExpansionPercent >= 10 && _maxSupplyExpansionPercent <= 1000, "_maxSupplyExpansionPercent: out of range"); // [0.1%, 10%]
        require(_maxSupplyExpansionPercentInDebtPhase >= 10 && _maxSupplyExpansionPercentInDebtPhase <= 1500, "_maxSupplyExpansionPercentInDebtPhase: out of range"); // [0.1%, 15%]
        require(_maxSupplyExpansionPercent <= _maxSupplyExpansionPercentInDebtPhase, "_maxSupplyExpansionPercent is over _maxSupplyExpansionPercentInDebtPhase");
        maxSupplyExpansionPercent = _maxSupplyExpansionPercent;
        maxSupplyExpansionPercentInDebtPhase = _maxSupplyExpansionPercentInDebtPhase;
    }

    function setSeigniorageExpansionRate(uint256 _seigniorageExpansionRate) external onlyAdmin {
        require(_seigniorageExpansionRate >= 0 && _seigniorageExpansionRate <= 20000, "out of range"); // [0%, 200%]
        seigniorageExpansionRate = _seigniorageExpansionRate;
    }

    function setJUNBDepletionFloorPercent(uint256 _junbDepletionFloorPercent) external onlyAdmin {
        require(_junbDepletionFloorPercent >= 500 && _junbDepletionFloorPercent <= 10000, "out of range"); // [5%, 100%]
        junbDepletionFloorPercent = _junbDepletionFloorPercent;
    }

    function setMaxSupplyContractionPercent(uint256 _maxSupplyContractionPercent) external onlyAdmin {
        require(_maxSupplyContractionPercent >= 100 && _maxSupplyContractionPercent <= 1500, "out of range"); // [0.1%, 15%]
        maxSupplyContractionPercent = _maxSupplyContractionPercent;
    }

    function setMaxDeptRatioPercent(uint256 _maxDeptRatioPercent) external onlyAdmin {
        require(_maxDeptRatioPercent >= 1000 && _maxDeptRatioPercent <= 10000, "out of range"); // [10%, 100%]
        maxDeptRatioPercent = _maxDeptRatioPercent;
    }    

    function setTeamFund(address _teamFund) external onlyAdmin {
        require(_teamFund != address(0), "zero");
        teamFund = _teamFund;
    }

    
    function setTeamFundSharedPercent(uint256 _teamFundSharedPercent) external onlyAdmin {
        require(_teamFundSharedPercent <= 3000, "out of range"); // <= 30%
        teamFundSharedPercent = _teamFundSharedPercent;
    }
    

    function setBuyBackFund(address _buyBackFund) external onlyAdmin {
        require(_buyBackFund != address(0), "zero");
        buyBackFund = _buyBackFund;
    }

    function setBuyBackFundExpansionRate(uint256 _buyBackFundExpansionRate) external onlyAdmin {
        require(_buyBackFundExpansionRate <= 10000 && _buyBackFundExpansionRate >= 0, "out of range"); // under 100%
        buyBackFundExpansionRate = _buyBackFundExpansionRate;
    }

    function setMaxBuyBackFundExpansionRate(uint256 _maxBuyBackFundExpansion) external onlyAdmin {
        require(_maxBuyBackFundExpansion <= 1000 && _maxBuyBackFundExpansion >= 0, "out of range"); // under 10%
        maxBuyBackFundExpansion = _maxBuyBackFundExpansion;
    }

    function setAllocateSeigniorageSalary(uint256 _allocateSeigniorageSalary) external onlyAdmin {
        require(_allocateSeigniorageSalary <= 100 ether, "Treasury: dont pay too much");
        allocateSeigniorageSalary = _allocateSeigniorageSalary;
    }

    function setRedeemPenaltyRate(uint256 _redeemPenaltyRate) external onlyAdmin {
        require(_redeemPenaltyRate <= 1 ether && _redeemPenaltyRate >= 0.9 ether, "out of range");
        redeemPenaltyRate = _redeemPenaltyRate;
    }

    function setMintingFactorForPayingDebt(uint256 _mintingFactorForPayingDebt) external onlyAdmin {
        require(_mintingFactorForPayingDebt >= 10000 && _mintingFactorForPayingDebt <= 20000, "_mintingFactorForPayingDebt: out of range"); // [100%, 200%]
        mintingFactorForPayingDebt = _mintingFactorForPayingDebt;
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    function _updateJUNPrice() internal {
        IOracle(junOracle).update();
    }

    function buyJUNB(uint256 _junAmount, uint256 targetPrice) external onlyOneBlock checkCondition checkOperator {
        require(_junAmount > 0, "Treasury: cannot purchase junbs with zero amount");

        uint256 junPrice = getJUNPrice();
        require(junPrice == targetPrice, "Treasury: jun price moved");
        require(
            junPrice < junPriceOne, // price < $1
            "Treasury: junPrice not eligible for junb purchase"
        );

        require(_junAmount <= roundSupplyContractionLeft, "Treasury: not enough junb left to purchase");

        uint256 _rate = getJUNBDiscountRate();
        require(_rate > 0, "Treasury: invalid junb rate");

        uint256 _junbAmount = _junAmount.mul(_rate).div(1e18);
        uint256 junSupply = IERC20(jun).totalSupply();
        uint256 newJUNBSupply = IERC20(junb).totalSupply().add(_junbAmount);
        require(newJUNBSupply <= junSupply.mul(maxDeptRatioPercent).div(10000), "over max debt ratio");

        IJUNAsset(jun).burnFrom(msg.sender, _junAmount);
        IJUNAsset(junb).mint(msg.sender, _junbAmount);

        roundSupplyContractionLeft = roundSupplyContractionLeft.sub(_junAmount);

        emit BoughtJUNB(msg.sender, _junAmount, _junbAmount);
    }

    function redeemJUNB(uint256 _junbAmount, uint256 targetPrice) external onlyOneBlock checkCondition checkOperator {
        require(_junbAmount > 0, "Treasury: cannot redeem junbs with zero amount");

        uint256 junPrice = getJUNPrice();
        require(junPrice == targetPrice, "Treasury: jun price moved");
        
        uint256 _junAmount;
        uint256 _rate;

        if (junPrice >= junPriceOne) {
            _rate = getJUNBPremiumRate();
            require(_rate > 0, "Treasury: invalid junb rate");
            
            _junAmount = _junbAmount.mul(_rate).div(1e18);
            
            require(IERC20(jun).balanceOf(address(this)) >= _junAmount, "Treasury: treasury has no more budget");

            seigniorageSaved = seigniorageSaved.sub(Math.min(seigniorageSaved, _junAmount));
            IJUNAsset(junb).burnFrom(msg.sender, _junbAmount);
            IERC20(jun).safeTransfer(msg.sender, _junAmount);
        }
        else {
            require(redeemPenaltyRate > 0, "Treasury: not allow");
            _junAmount = _junbAmount.mul(redeemPenaltyRate).div(1e18);
            IJUNAsset(junb).burnFrom(msg.sender, _junbAmount);
            IJUNAsset(jun).mint(msg.sender, _junAmount);
        }

        emit RedeemedJUNB(msg.sender, _junAmount, _junbAmount);
    }

    function _sendToBoardRoom(uint256 _amount) internal {
        IJUNAsset(jun).mint(address(this), _amount);
        if (teamFundSharedPercent > 0) {
            uint256 _teamFundSharedAmount = _amount.mul(teamFundSharedPercent).div(10000);
            IERC20(jun).transfer(teamFund, _teamFundSharedAmount);
            emit TeamFundFunded(now, _teamFundSharedAmount);
            _amount = _amount.sub(_teamFundSharedAmount);
        }
        IERC20(jun).safeApprove(boardroom, 0);
        IERC20(jun).safeApprove(boardroom, _amount);
        IBoardroom(boardroom).allocateSeigniorage(_amount);
        emit BoardroomFunded(now, _amount);
    }

    function allocateSeigniorage() external onlyOneBlock checkCondition checkEpoch checkOperator {
        _updateJUNPrice();
        previousRoundJUNPrice = getJUNPrice();
        uint256 junSupply = IERC20(jun).totalSupply().sub(seigniorageSaved);
        if (round < bootstrapRounds) {
            _sendToBoardRoom(junSupply.mul(bootstrapSupplyExpansionPercent).div(10000));
        } else {
            if (previousRoundJUNPrice > junPriceOne) {
                // Expansion (JUN Price > 1$): there is some seigniorage to be allocated
                uint256 junbSupply = IERC20(junb).totalSupply();
                uint256 _percentage = previousRoundJUNPrice.sub(junPriceOne).mul(seigniorageExpansionRate).div(10000);
                uint256 _savedForJUNB;
                uint256 _savedForBoardRoom;
                if (seigniorageSaved >= junbSupply.mul(junbDepletionFloorPercent).div(10000)) {// saved enough to pay dept, mint as usual rate
                    uint256 _mse = maxSupplyExpansionPercent.mul(1e14);
                    if (_percentage > _mse) {
                        _percentage = _mse;
                    }
                    _savedForBoardRoom = junSupply.mul(_percentage).div(1e18);
                } else {// have not saved enough to pay dept, mint more
                    uint256 _mse = maxSupplyExpansionPercentInDebtPhase.mul(1e14);
                    if (_percentage > _mse) {
                        _percentage = _mse;
                    }
                    uint256 _seigniorage = junSupply.mul(_percentage).div(1e18);
                    _savedForBoardRoom = _seigniorage.mul(seigniorageExpansionFloorPercent).div(10000);
                    _savedForJUNB = _seigniorage.sub(_savedForBoardRoom);
                    if (mintingFactorForPayingDebt > 0) {
                        _savedForJUNB = _savedForJUNB.mul(mintingFactorForPayingDebt).div(10000);
                    }
                }
                if (_savedForBoardRoom > 0) {
                    _sendToBoardRoom(_savedForBoardRoom);
                }
                if (_savedForJUNB > 0) {
                    seigniorageSaved = seigniorageSaved.add(_savedForJUNB);
                    IJUNAsset(jun).mint(address(this), _savedForJUNB);
                    emit TreasuryFunded(now, _savedForJUNB);
                }
            }
        }
        // buy-back fund mint
        if (previousRoundJUNPrice > junPriceOne) {
            uint256 _buyBackRate = previousRoundJUNPrice.sub(junPriceOne).mul(buyBackFundExpansionRate).div(10000);
            uint256 _maxBuyBackRate = maxBuyBackFundExpansion.mul(1e14);
            if (_buyBackRate > _maxBuyBackRate) {
                _buyBackRate = _maxBuyBackRate;
            }
            uint256 _savedForBuyBackFund = junSupply.mul(_buyBackRate).div(1e18);
            if (_savedForBuyBackFund > 0) {
                IJUNAsset(jun).mint(address(buyBackFund), _savedForBuyBackFund);
                emit BuyBackFunded(now, _savedForBuyBackFund);
            }
        }
        if (allocateSeigniorageSalary > 0) {
            IJUNAsset(jun).mint(address(msg.sender), allocateSeigniorageSalary);
        }
    }

    function governanceRecoverUnsupported(IERC20 _token, uint256 _amount, address _to) external onlyAdmin {
        // do not allow to drain core tokens
        require(address(_token) != address(jun), "jun");
        require(address(_token) != address(junb), "junb");
        require(address(_token) != address(juns), "juns");
        _token.safeTransfer(_to, _amount);
    }

    function burnJUNFromBuyBackFund(uint256 _amount) external onlyAdmin {
        require(_amount > 0, "Treasury: cannot burn jun with zero amount");
        IJUNAsset(jun).burnFrom(address(buyBackFund), _amount);
        burnJUNAmount = burnJUNAmount.add(_amount);
        emit BuyBackBurnedJUN(now, _amount);
    }

     /* ========== BOARDROOM CONTROLLING FUNCTIONS ========== */

    function boardroomSetLockUp(uint256 _withdrawLockupRounds, uint256 _rewardLockupRounds) external onlyAdmin {
        IBoardroom(boardroom).setLockUp(_withdrawLockupRounds, _rewardLockupRounds);
    }

    function boardroomAllocateSeigniorage(uint256 amount) external onlyAdmin {
        IBoardroom(boardroom).allocateSeigniorage(amount);
    }

    function boardroomGovernanceRecoverUnsupported(address _token, uint256 _amount, address _to) external onlyAdmin {
        IBoardroom(boardroom).governanceRecoverUnsupported(_token, _amount, _to);
    }
}
