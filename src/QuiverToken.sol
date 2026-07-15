// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title QuiverToken
/// @notice Fixed-supply ERC20 launched by the Quiver factory on Robinhood Chain.
///         Deliberately minimal — no owner functions, no mint, no permit/votes,
///         no transfer hooks — so security scanners and decompilers see a plain
///         ERC20 with nothing to flag. Image/metadata/context are set once at
///         construction; the app reads them from the TokenCreated event, the
///         getters below are an on-chain convenience.
/// @dev Constructor signature is shared with the previous token version so
///      QuiverDeployer works unchanged.
contract QuiverToken is ERC20 {
    address private immutable _originalAdmin;
    string private _metadata;
    string private _context;
    string private _image;

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 maxSupply_,
        address admin_,
        string memory image_,
        string memory metadata_,
        string memory context_,
        uint256 initialSupplyChainId_
    ) ERC20(name_, symbol_) {
        _originalAdmin = admin_;
        _image = image_;
        _metadata = metadata_;
        _context = context_;

        // Only mint initial supply on a single chain
        if (block.chainid == initialSupplyChainId_) {
            _mint(msg.sender, maxSupply_);
        }
    }

    /// @notice Kept for ABI compatibility — the creator; there is no mutable admin.
    function admin() external view returns (address) {
        return _originalAdmin;
    }

    function originalAdmin() external view returns (address) {
        return _originalAdmin;
    }

    function imageUrl() external view returns (string memory) {
        return _image;
    }

    function metadata() external view returns (string memory) {
        return _metadata;
    }

    function context() external view returns (string memory) {
        return _context;
    }

    // convenience function to get all data in one call
    function allData()
        external
        view
        returns (
            address originalAdmin,
            address admin,
            string memory image,
            string memory metadata,
            string memory context
        )
    {
        return (_originalAdmin, _originalAdmin, _image, _metadata, _context);
    }
}
