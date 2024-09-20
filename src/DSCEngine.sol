// SPDX-License-Identifier: MIT
// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions
pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/*
 * @title DSCEngine
 * @author Abidogun AbdulAzeez
 *
 * This system is designed to be as minimal as possible, and have the tokens maintain a 1 token = $1 Dollar Pegged.
 * This stablecoin has the properties:
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algorithimically Stable
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of all collateral <= $backed the value of all the DSC
 *
 * It is similar to DAI if DAI had no governance, no fees, and was only backed by wETH and wBTC.
 *
 * @notice This contract is the core of the DSC system. It handles all the logic for mining and redeeming DSC, as well as depositing & withdrawing collateral.
 * @notice This contract is VERY loosely based on MakerDao DSS (DAI) system.
 */
contract DSCEngine is ReentrancyGuard {
    ///////////////////////////////
    ///////// Errors ///////////
    //////////////////////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__tokenAddressesAndPriceFeedAdressesMustBeSameLength();
    error DSCEngine__NotAllowedToken(address token);
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOkay();
    error DSCEngine__HealthFactorNotImproved();

    ///////////////////////////////
    ////////// Types /////////////
    //////////////////////////////
    using OracleLib for AggregatorV3Interface;

    ///////////////////////////////
    ////// State Variables ////////
    //////////////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // this means a 10% bonus

    mapping(address token => address priceFeed) private s_priceFeeds; // tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount))
        private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    ///////////////////////////////
    ///////// Events ///////////
    //////////////////////////////
    event CollateralDeposited(
        address indexed user,
        address indexed token,
        uint256 indexed amount
    );

    event CollateralRedeemed(
        address indexed redeemedFrom,
        address indexed redeemedTo,
        address indexed token,
        uint256 amount
    );

    ///////////////////////////////
    ///////// Modifiers ///////////
    //////////////////////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken(token);
        }
        _;
    }

    ///////////////////////////////
    ///////// Functions ///////////
    //////////////////////////////

    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address dscAddress
    ) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__tokenAddressesAndPriceFeedAdressesMustBeSameLength();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ///////////////////////////////
    //// External Functions ///////
    //////////////////////////////

    /**
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     * @param amountDscToMint The amount of the decentralized stable coin to mint
     */
    // * Deposit collateral and mint the DSC token
    // This is how users acquire the stablecoin, they deposit collateral greater than the value of the DSC minted
    // User to deposit their DAI or BTC and mint the DSC
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @notice follows CEI pattern
     * @param tokenCollateralAddress The address of thr token to be deposited as collateral
     * @param amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    )
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][
            tokenCollateralAddress
        ] += amountCollateral;
        // since we are updating a state, then we should emit an event
        emit CollateralDeposited(
            msg.sender,
            tokenCollateralAddress,
            amountCollateral
        );
        bool success = IERC20(tokenCollateralAddress).transferFrom(
            msg.sender,
            address(this),
            amountCollateral
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @param tokenCollateralAddress the collateral to redeem
     * @param amountCollateral The amount of collateral to redeem
     * @param amountDscToBurn The amount of DSC to burn
     * This function burns DSC and redeem underlying collateral in one transaction
     */
    /* Redeem their collateral for DSC
    * Users will need to be able to return DSC to the protocol in exchange for their underlying collateral
    * Burn DSC
    User to redeem the DSC. Once they're done, they can turn the stablecoin to whatever collateral they will like to redeem to */
    function redeemCollateralForDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToBurn
    ) external {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeemCollateral() already checks health factor
    }

    // Inorder to redeem collateral
    // 1. health factor must be over 1 after collateral pulled
    function redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) public moreThanZero(amountCollateral) nonReentrant {
        _redeemCollateral(
            msg.sender,
            msg.sender,
            tokenCollateralAddress,
            amountCollateral
        );
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice  follows CEI pattern
     * @param amountDscToMint The amount of decentralized stablecoin to mint
     * @notice they must have more collateral value than the minimum threshold
     */
    // We need to check if the collateral value > DSC value
    function mintDsc(
        uint256 amountDscToMint
    ) public moreThanZero(amountDscToMint) {
        s_DSCMinted[msg.sender] += amountDscToMint;
        // If they minted too much
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    //user to able to burn their DSC
    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(msg.sender, msg.sender, amount);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // /**
    //  *@notice
    // * @param collateral: The ERC20 token address of the collateral you're using to make the protocol solvent again.
    // * This is collateral that you're going to take from the user who is insolvent.
    // * In return, you have to burn your DSC to pay off their debt, but you don't pay off your own.
    // * @param user: The user who is insolvent. They have to have a _healthFactor below MIN_HEALTH_FACTOR
    // * @param debtToCover: The amount of DSC you want to burn to cover the user's debt.
    // *
    // * @notice: You can partially liquidate a user.
    // * @notice: You will get a 10% LIQUIDATION_BONUS for taking the users funds.
    // * @notice: This function working assumes that the protocol will be roughly 150% overcollateralized in order for this
    // to work.
    // * @notice: A known bug would be if the protocol was only 100% collateralized, we wouldn't be able to liquidate
    // anyone.
    // * For example, if the price of the collateral plummeted before anyone could be liquidated.
    // */
    /*
    * Now that users are able to deposit collateral and mint, we need to protect against the protocol becoming under-collateralized. If the value of deposited collateral falls, such that users' Health Factors are broken, we need a method by which another user can liquidate those unhealthy positions to secure the value of the stablecoin.

    Users who assist the protocol by liquidating unhealthy positions will be rewarded with the collateral for the position they've closed, which will exceed the value of the DSC burnt by virtue of our liquidation threshold.

    To illustrate:

    * User deposited $100 in collateral and mints $50 in DSC
    * Collateral value falls to \$75, breaking the user's Health Factor (0.75)
    * A liquidator burns \$50 in DSC to close the position
    * The liquidator is rewarded \$75 in collateral
    * The liquidator has profited \$25

      If the value of a user's collateral quickly falls, users will need a way to quickly rectify the collateralization of their DSC.
     * The ability to liquidate an account
     * Because our protocol must always be over-collateralized (more collateral must be deposited then DSC is minted), if a user's collateral value falls below what's required to support their minted DSC, they can be liquidated. Liquidation allows other users to close an under-collateralized position
     *  to set a threshold on the user and remove them from the system as soon as they're closed to the DSC value so as not to damage the protocol */
    function liquidate(
        address collateral,
        address user,
        uint256 debtToCover
    ) external moreThanZero(debtToCover) nonReentrant {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOkay();
        }

        // Now we want to burn their DSC "debt"
        // And take their collateral
        // Bad User: $140 ETH, $100 DSC
        // debtToCover = $100
        // $100 of DSC == ??? ETH?
        // 0.05 ETH
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(
            collateral,
            debtToCover
        );
        // and give them a 10% bonus
        // So we are giving the liquidator $110 of WETH for 100 DSC
        // We should implement a feature to liquidate in the event the protocol is insolvent
        // And sweep extra amounts into a treasury

        // 0.05 ETH * .1 = 0.005 ETH. Getting 0.055
        uint256 bonusCollateral = (tokenAmountFromDebtCovered *
            LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered +
            bonusCollateral;
        // Then we Redeem
        _redeemCollateral(
            user,
            msg.sender,
            collateral,
            totalCollateralToRedeem
        );
        // Now we burn
        _burnDsc(user, msg.sender, debtToCover);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // View an account's healthFactor
    //healthFactor will be defined as a certain ratio of collateralization a user has for the DSC they've minted. As the value of a user's collateral falls, as will their healthFactor, if no changes to DSC held are made. If a user's healthFactor falls below a defined threshold, the user will be at risk of liquidation.
    // eg. If the threshold to liquidate is 150% collateralization, an account with $75 in ETH can support $50 in DSC. If the value of ETH falls to \$74, the healthFactor is broken and the account can be liquidated

    ///////////////////////////////////////
    //// Private & Internal Functions /////
    //////////////////////////////////////

    /**
     * @dev Low-level internal function, do not call unless function calling it is checking for healthfactor being broken
     */
    function _burnDsc(
        address onBehalfOf,
        address dscFrom,
        uint256 amountDscToBurn
    ) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(
            dscFrom,
            address(this),
            amountDscToBurn
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(
        address from,
        address to,
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) private {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(
            from,
            to,
            tokenCollateralAddress,
            amountCollateral
        );
        //
        bool success = IERC20(tokenCollateralAddress).transfer(
            to,
            amountCollateral
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function _getAccountInformation(
        address user
    )
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValueInUsd(user);
    }

    /**
     * Returns how lose to liquidation is
     * If a user goes below 1, then they can't get liquidated
     */
    function _healthFactor(address user) private view returns (uint256) {
        // total DSC Minted
        // total collateral VALUE
        // return the ratio of collateral value to DSC minted
        // if the ratio is less than 1, then they can't get liquidated
        // if the ratio is greater than 1, then they can get liquidated
        // if the ratio is equal to 1, then they are at the threshold
        // return the ratio
        (
            uint256 totalDscMinted,
            uint256 collateralValueInUsd
        ) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function _getUsdValue(
        address token,
        uint256 amount
    ) private view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();
        // 1 ETH = $1000
        // The returned value from CL will be 1000 * 1e8
        // So we need to divide by 1e8 to get the actual price
        return
            ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION; // (1000* 1e18 *(1e10)) * 1000 * 1e18;
    }

    function _calculateHealthFactor(
        uint256 totalDscMinted,
        uint256 collateralValueInUsd
    ) internal pure returns (uint256) {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd *
            LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    // 1. check health factor (do they have enough collateral?)
    //2. revert if they don't
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    ///////////////////////////////////////
    //// Public & External view Functions /////
    //////////////////////////////////////

    function calculateHealthFactor(
        uint256 totalDscMinted,
        uint256 collateralValueInUsd
    ) external pure returns (uint256) {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getCollateralBalanceOfUser(
        address user,
        address token
    ) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getTokenAmountFromUsd(
        address token,
        uint256 usdAmountInWei
    ) public view returns (uint256 totalCollateralValueInUsd) {
        // price of ETH (token)
        // $/ETH ETH??
        // $2000 / ETH, $1000 = 0.5 ETH
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();
        return
            (usdAmountInWei * PRECISION) /
            (uint256(price) * ADDITIONAL_FEED_PRECISION); // ($10e18 * 1e18) / ($2000 *1e10)
    }

    function getAccountCollateralValueInUsd(
        address user
    ) public view returns (uint256 totalCollateralValueInUsd) {
        //loop through each collateral token, get the amount they have deposited, and map it to the price, to get the USD value
        //return the total USD value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += _getUsdValue(token, amount);
        }

        return totalCollateralValueInUsd;
    }

    function getUsdValue(
        address token,
        uint256 amount
    ) external view returns (uint256) {
        return _getUsdValue(token, amount);
    }

    function getAccountInformation(
        address user
    )
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getCollateralTokenPriceFeed(
        address token
    ) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }
}
