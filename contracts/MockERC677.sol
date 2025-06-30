// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockERC677
 * @notice A mock ERC677 token for testing the StableSwap pool
 * @dev Extends ERC20 with transferAndCall functionality
 */
contract MockERC677 is ERC20 {
    uint8 private _decimals;
    
    // Event emitted when transferAndCall is called
    event TransferAndCall(address indexed from, address indexed to, uint256 value, bytes data);

    /**
     * @notice Constructor for the mock token
     * @param name_ Name of the token
     * @param symbol_ Symbol of the token
     * @param decimals_ Number of decimals for the token
     * @param initialSupply Initial supply to mint to the deployer
     */
    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        uint256 initialSupply
    ) ERC20(name_, symbol_) {
        _decimals = decimals_;
        
        // Mint initial supply to the deployer
        if (initialSupply > 0) {
            _mint(msg.sender, initialSupply);
        }
    }

    /**
     * @notice Returns the number of decimals used by the token
     * @return The number of decimals
     */
    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /**
     * @notice Mints tokens to a recipient (for testing only)
     * @param to Address to receive the minted tokens
     * @param amount Amount of tokens to mint
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /**
     * @notice Burns tokens from the caller
     * @param amount Amount of tokens to burn
     */
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
    
    /**
     * @notice Transfer tokens and call the receiver's tokenFallback function
     * @param _to Address to receive the tokens
     * @param _value Amount of tokens to transfer
     * @param _data Additional data to send to the receiver
     * @return success Whether the operation was successful
     */
    function transferAndCall(address _to, uint256 _value, bytes calldata _data) external returns (bool success) {
        transfer(_to, _value);
        emit TransferAndCall(msg.sender, _to, _value, _data);
        
        if (isContract(_to)) {
            contractFallback(_to, _value, _data);
        }
        return true;
    }
    
    /**
     * @notice Call the contractReceiver's onTokenTransfer function
     * @param _to Address of the contract receiving the tokens
     * @param _value Amount of tokens transferred
     * @param _data Additional data to send to the receiver
     */
    function contractFallback(address _to, uint256 _value, bytes calldata _data) private {
        // Interface for ERC677 token receivers
        ERC677Receiver receiver = ERC677Receiver(_to);
        receiver.onTokenTransfer(msg.sender, _value, _data);
    }
    
    /**
     * @notice Check if an address is a contract
     * @param _addr Address to check
     * @return True if the address is a contract
     */
    function isContract(address _addr) private view returns (bool) {
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(_addr)
        }
        return codeSize > 0;
    }
}

/**
 * @title ERC677Receiver
 * @dev Interface for contracts that will receive ERC677 tokens
 */
interface ERC677Receiver {
    function onTokenTransfer(address _sender, uint256 _value, bytes calldata _data) external;
}