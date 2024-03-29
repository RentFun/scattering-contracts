// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";

import {SafeBox, CollectionState, AuctionInfo, AuctionType} from "./Structs.sol";
import "./User.sol";
import "./Collection.sol";
import "./Helper.sol";
import "../Errors.sol";
import "../Constants.sol";
import "../interface/IScattering.sol";
import {SafeBoxLib} from "./SafeBox.sol";

library AuctionLib {
    using SafeCast for uint256;
    using CollectionLib for CollectionState;
    using SafeBoxLib for SafeBox;
    using UserLib for UserFloorAccount;
    using Helper for CollectionState;

    event AuctionStarted(
        address indexed trigger,
        address indexed collection,
        uint64[] activityIds,
        uint256[] tokenIds,
        AuctionType typ,
        address settleToken,
        uint256 minimumBid,
        uint256 feeRateBips,
        uint256 auctionEndTime,
        uint256 safeBoxExpiryTs,
        uint256 adminFee
    );

    event NewTopBidOnAuction(
        address indexed bidder,
        address indexed collection,
        uint64 activityId,
        uint256 tokenId,
        uint256 bidAmount,
        uint256 auctionEndTime,
        uint256 safeBoxExpiryTs
    );

    event AuctionEnded(
        address indexed winner,
        address indexed collection,
        uint64 activityId,
        uint256 tokenId,
        uint256 safeBoxKeyId,
        uint256 collectedFunds
    );

    function ownerInitAuctions(
        CollectionState storage collection,
        mapping(address => UserFloorAccount) storage userAccounts,
        //address creditToken,
        address collectionId,
        uint256[] memory nftIds,
        address token,
        uint256 minimumBid
    ) public {
        UserFloorAccount storage userAccount = userAccounts[msg.sender];
        uint256 adminFee = Constants.AUCTION_COST * nftIds.length;
        /// transfer fee to contract account
        userAccount.transferToken(userAccounts[address(this)], address(collection.fragmentToken), adminFee, true);

        AuctionInfo memory auctionTemplate;
        auctionTemplate.endTime = uint96(block.timestamp + Constants.AUCTION_INITIAL_PERIODS);
        auctionTemplate.bidTokenAddress = token;
        auctionTemplate.minimumBid = minimumBid.toUint96();
        auctionTemplate.triggerAddress = msg.sender;
        auctionTemplate.feeRateBips = uint32(getAuctionFeeRate());
        auctionTemplate.lastBidAmount = 0;
        auctionTemplate.lastBidder = address(0);
        auctionTemplate.typ = AuctionType.Owned;

        (uint64[] memory activityIds, uint192 newExpiryTs) = _ownerInitAuctions(collection, nftIds, auctionTemplate);

        emit AuctionStarted(
            msg.sender,
            collectionId,
            activityIds,
            nftIds,
            auctionTemplate.typ,
            token,
            minimumBid,
            auctionTemplate.feeRateBips,
            auctionTemplate.endTime,
            newExpiryTs,
            adminFee
        );
    }

    function _ownerInitAuctions(
        CollectionState storage collectionState,
        uint256[] memory nftIds,
        AuctionInfo memory auctionTemplate
    ) private returns (uint64[] memory activityIds, uint32 newExpiryTs) {
        newExpiryTs = uint32(auctionTemplate.endTime + Constants.AUCTION_COMPLETE_GRACE_PERIODS);

        activityIds = new uint64[](nftIds.length);
        for (uint256 i = 0; i < nftIds.length; ) {
            if (collectionState.hasActiveActivities(nftIds[i])) revert Errors.NftHasActiveActivities();

            SafeBox storage safeBox = collectionState.useSafeBoxAndKey(msg.sender, nftIds[i]);

            safeBox.expiryTs = newExpiryTs;

            activityIds[i] = collectionState.generateNextActivityId();

            auctionTemplate.activityId = activityIds[i];
            collectionState.activeAuctions[nftIds[i]] = auctionTemplate;

            unchecked {
                ++i;
            }
        }
    }

    function initAuctionOnExpiredSafeBoxes(
        CollectionState storage collection,
        mapping(address => UserFloorAccount) storage userAccounts,
        // address creditToken,
        address collectionId,
        uint256[] memory nftIds,
        address bidToken,
        uint256 bidAmount
    ) public {
        if (bidAmount < Constants.AUCTION_ON_EXPIRED_MINIMUM_BID) revert Errors.InvalidParam();

        AuctionInfo memory auctionTemplate;
        auctionTemplate.endTime = uint96(block.timestamp + Constants.AUCTION_INITIAL_PERIODS);
        auctionTemplate.bidTokenAddress = bidToken;
        auctionTemplate.minimumBid = bidAmount.toUint96();
        auctionTemplate.triggerAddress = msg.sender;
        auctionTemplate.feeRateBips = uint32(getAuctionFeeRate());
        auctionTemplate.lastBidAmount = bidAmount.toUint96();
        auctionTemplate.lastBidder = msg.sender;
        auctionTemplate.typ = AuctionType.Expired;

        (uint64[] memory activityIds, uint192 newExpiry) = _initAuctionOnExpiredSafeBoxes(
            collection,
            nftIds,
            auctionTemplate
        );

        uint256 adminFee = Constants.AUCTION_ON_EXPIRED_SAFEBOX_COST * nftIds.length;
        {
            userAccounts[msg.sender].transferToken(
                userAccounts[address(this)],
                bidToken,
                bidAmount * nftIds.length,
                false
            );
            if (adminFee > 0) {
                userAccounts[msg.sender].transferToken(
                    userAccounts[address(this)],
                    address(collection.fragmentToken),
                    adminFee,
                    true
                );
            }
        }

        emit AuctionStarted(
            msg.sender,
            collectionId,
            activityIds,
            nftIds,
            auctionTemplate.typ,
            bidToken,
            bidAmount,
            auctionTemplate.feeRateBips,
            auctionTemplate.endTime,
            newExpiry,
            // false,
            adminFee
        );
    }

    function _initAuctionOnExpiredSafeBoxes(
        CollectionState storage collectionState,
        uint256[] memory nftIds,
        AuctionInfo memory auctionTemplate
    ) private returns (uint64[] memory activityIds, uint32 newExpiry) {
        newExpiry = uint32(auctionTemplate.endTime + Constants.AUCTION_COMPLETE_GRACE_PERIODS);

        activityIds = new uint64[](nftIds.length);
        for (uint256 idx; idx < nftIds.length; ) {
            uint256 nftId = nftIds[idx];
            if (collectionState.hasActiveActivities(nftId)) revert Errors.NftHasActiveActivities();

            SafeBox storage safeBox = collectionState.useSafeBox(nftId);
            if (!safeBox.isSafeBoxExpired()) revert Errors.SafeBoxHasNotExpire();
            if (Helper.isAuctionPeriodOver(safeBox)) revert Errors.SafeBoxAuctionWindowHasPassed();

            activityIds[idx] = collectionState.generateNextActivityId();
            auctionTemplate.activityId = activityIds[idx];
            collectionState.activeAuctions[nftId] = auctionTemplate;

            /// @del We keep the owner of safebox unchanged, and it will be used to distribute auction funds
            /// todo Temporarily transfer the key to the contract
            safeBox.expiryTs = newExpiry;
            // safeBox.keyId = SafeBoxLib.SAFEBOX_KEY_NOTATION;
            collectionState.transferSafeBox(safeBox, address(this));

            unchecked {
                ++idx;
            }
        }
    }

    function initAuctionOnVault(
        CollectionState storage collection,
        mapping(address => UserFloorAccount) storage userAccounts,
        //        address creditToken,
        address collectionId,
        uint256[] memory vaultIdx,
        address bidToken,
        uint96 bidAmount
    ) public {
        if (vaultIdx.length != 1) revert Errors.InvalidParam();
        if (bidAmount < Constants.AUCTION_ON_VAULT_MINIMUM_BID) revert Errors.InvalidParam();

        AuctionInfo memory auctionTemplate;
        auctionTemplate.endTime = uint96(block.timestamp + Constants.AUCTION_INITIAL_PERIODS);
        auctionTemplate.bidTokenAddress = bidToken;
        auctionTemplate.minimumBid = bidAmount;
        auctionTemplate.triggerAddress = msg.sender;
        auctionTemplate.feeRateBips = 0;
        auctionTemplate.lastBidAmount = bidAmount;
        auctionTemplate.lastBidder = msg.sender;
        auctionTemplate.typ = AuctionType.Vault;

        SafeBox memory safeboxTemplate = SafeBox({
            keyId: Helper.generateNextKeyId(collection),
            expiryTs: uint32(auctionTemplate.endTime + Constants.AUCTION_COMPLETE_GRACE_PERIODS),
            owner: address(this)
        });

        uint256[] memory nftIds = new uint256[](vaultIdx.length);
        uint64[] memory activityIds = new uint64[](vaultIdx.length);

        /// vaultIdx keeps asc order
        for (uint256 i = vaultIdx.length; i > 0; ) {
            unchecked {
                --i;
            }

            if (vaultIdx[i] >= collection.freeTokenIds.length) revert Errors.InvalidParam();
            uint256 nftId = collection.freeTokenIds[vaultIdx[i]];
            nftIds[i] = nftId;

            collection.addSafeBox(nftId, safeboxTemplate);

            auctionTemplate.activityId = collection.generateNextActivityId();
            collection.activeAuctions[nftId] = auctionTemplate;
            activityIds[i] = auctionTemplate.activityId;

            collection.freeTokenIds[vaultIdx[i]] = collection.freeTokenIds[collection.freeTokenIds.length - 1];
            collection.freeTokenIds.pop();
        }

        userAccounts[msg.sender].transferToken(
            userAccounts[address(this)],
            auctionTemplate.bidTokenAddress,
            bidAmount * nftIds.length,
            false
        );

        emit AuctionStarted(
            msg.sender,
            collectionId,
            activityIds,
            nftIds,
            auctionTemplate.typ,
            auctionTemplate.bidTokenAddress,
            bidAmount,
            auctionTemplate.feeRateBips,
            auctionTemplate.endTime,
            safeboxTemplate.expiryTs,
            0
        );
    }

    struct BidParam {
        uint256 nftId;
        uint96 bidAmount;
        address bidder;
        uint256 extendDuration;
        uint256 minIncrPct;
    }

    function placeBidOnAuction(
        CollectionState storage collection,
        mapping(address => UserFloorAccount) storage userAccounts,
        // address creditToken,
        address collectionId,
        uint256 nftId,
        uint256 bidAmount /*,
        uint256 bidOptionIdx*/
    ) public {
        uint256 prevBidAmount;
        address prevBidder;
        {
            Constants.AuctionBidOption memory bidOption = Constants.getBidOption();

            (prevBidAmount, prevBidder) = _placeBidOnAuction(
                collection,
                BidParam(
                    nftId,
                    bidAmount.toUint96(),
                    msg.sender,
                    bidOption.extendDurationSecs,
                    bidOption.minimumRaisePct
                )
            );
        }

        AuctionInfo memory auction = collection.activeAuctions[nftId];

        address bidToken = auction.bidTokenAddress;
        userAccounts[msg.sender].transferToken(
            userAccounts[address(this)],
            bidToken,
            bidAmount,
            // bidToken == creditToken
            false
        );

        if (prevBidAmount > 0) {
            /// refund previous bid
            /// contract account no need to check credit requirements
            userAccounts[address(this)].transferToken(userAccounts[prevBidder], bidToken, prevBidAmount, false);
            userAccounts[prevBidder].withdraw(prevBidder, bidToken, prevBidAmount, false);
        }

        SafeBox memory safebox = collection.safeBoxes[nftId];
        emit NewTopBidOnAuction(
            msg.sender,
            collectionId,
            auction.activityId,
            nftId,
            bidAmount,
            auction.endTime,
            safebox.expiryTs
        );
    }

    function _placeBidOnAuction(
        CollectionState storage collectionState,
        BidParam memory param
    ) private returns (uint128 prevBidAmount, address prevBidder) {
        AuctionInfo storage auctionInfo = collectionState.activeAuctions[param.nftId];

        SafeBox storage safeBox = collectionState.useSafeBox(param.nftId);
        uint256 endTime = auctionInfo.endTime;
        {
            (prevBidAmount, prevBidder) = (auctionInfo.lastBidAmount, auctionInfo.lastBidder);
            // param check
            if (endTime == 0) revert Errors.AuctionNotExist();
            if (endTime <= block.timestamp) revert Errors.AuctionHasExpire();
            if (prevBidAmount >= param.bidAmount || auctionInfo.minimumBid > param.bidAmount) {
                revert Errors.AuctionBidIsNotHighEnough();
            }
            if (prevBidder == param.bidder) revert Errors.AuctionSelfBid();
            // owner starts auction, can not bid by himself
            if (auctionInfo.typ == AuctionType.Owned && param.bidder == safeBox.owner) revert Errors.AuctionSelfBid();

            if (prevBidAmount > 0 && !isValidNewBid(param.bidAmount, prevBidAmount, param.minIncrPct)) {
                revert Errors.AuctionInvalidBidAmount();
            }
        }

        /// Changing safebox key id which means the corresponding safebox key doesn't hold the safebox now
        // safeBox.keyId = SafeBoxLib.SAFEBOX_KEY_NOTATION;

        uint256 newAuctionEndTime = block.timestamp + param.extendDuration;
        if (newAuctionEndTime > endTime) {
            uint256 newSafeBoxExpiryTs = newAuctionEndTime + Constants.AUCTION_COMPLETE_GRACE_PERIODS;

            safeBox.expiryTs = uint32(newSafeBoxExpiryTs);
            auctionInfo.endTime = uint96(newAuctionEndTime);
        }

        auctionInfo.lastBidAmount = param.bidAmount;
        auctionInfo.lastBidder = param.bidder;
    }

    function settleAuctions(
        CollectionState storage collection,
        mapping(address => UserFloorAccount) storage userAccounts,
        address collectionId,
        uint256[] memory nftIds
    ) public {
        for (uint256 i; i < nftIds.length; ) {
            uint256 nftId = nftIds[i];
            SafeBox storage safeBox = Helper.useSafeBox(collection, nftId);

            if (safeBox.isSafeBoxExpired()) revert Errors.SafeBoxHasExpire();

            AuctionInfo memory auctionInfo = collection.activeAuctions[nftId];
            if (auctionInfo.endTime == 0) revert Errors.AuctionNotExist();
            if (auctionInfo.endTime > block.timestamp) revert Errors.AuctionHasNotCompleted();
            /// none bid on the action, can not be settled
            if (auctionInfo.lastBidder == address(0)) revert Errors.AuctionHasNotCompleted();

            (uint256 earning, ) = Helper.calculateActivityFee(auctionInfo.lastBidAmount, auctionInfo.feeRateBips);
            /// contract account no need to check credit requirements
            /// transfer earnings to old safebox owner
            if (safeBox.owner != address(this)) {
                userAccounts[address(this)].transferToken(
                    userAccounts[safeBox.owner],
                    auctionInfo.bidTokenAddress,
                    earning,
                    false
                );
                userAccounts[safeBox.owner].withdraw(safeBox.owner, auctionInfo.bidTokenAddress, earning, false);
            }

            /// transfer safebox
            address winner = auctionInfo.lastBidder;
            collection.transferSafeBox(safeBox, winner);

            delete collection.activeAuctions[nftId];

            emit AuctionEnded(
                winner,
                collectionId,
                auctionInfo.activityId,
                nftId,
                safeBox.keyId,
                auctionInfo.lastBidAmount
            );

            unchecked {
                ++i;
            }
        }
    }

    function isValidNewBid(uint256 newBid, uint256 previousBid, uint256 minRaisePct) private pure returns (bool) {
        uint256 minIncrement = (previousBid * minRaisePct) / 100;
        if (minIncrement < 1) {
            minIncrement = 1;
        }

        if (newBid < previousBid + minIncrement) {
            return false;
        }
        // think: always thought this should be previousBid....
        uint256 newIncrementAmount = newBid / 100;
        if (newIncrementAmount < 1) {
            newIncrementAmount = 1;
        }
        return newBid % newIncrementAmount == 0;
    }

    function getAuctionFeeRate() private pure returns (uint256) {
        return Constants.FREE_AUCTION_FEE_RATE_BIPS;
    }
}
