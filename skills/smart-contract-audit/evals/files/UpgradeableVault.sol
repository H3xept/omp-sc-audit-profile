// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

/// @notice Minimal ERC1967 proxy: stores the implementation in the EIP-1967 slot and delegates every call.
contract VaultProxy {
    bytes32 internal constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    constructor(address implementation, bytes memory initData) {
        assembly {
            sstore(_IMPLEMENTATION_SLOT, implementation)
        }
        (bool ok,) = implementation.delegatecall(initData);
        require(ok, "init failed");
    }

    fallback() external payable {
        assembly {
            let impl := sload(_IMPLEMENTATION_SLOT)
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}

abstract contract Initializable {
    uint8 private _initialized;

    modifier reinitializer(uint8 version) {
        require(_initialized <= version, "already initialized");
        _initialized = version;
        _;
    }

    function _disableInitializers() internal {
        _initialized = type(uint8).max;
    }
}

abstract contract UUPSUpgradeable {
    bytes32 internal constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function _authorizeUpgrade(address newImplementation) internal virtual;

    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable {
        _authorizeUpgrade(newImplementation);
        assembly {
            sstore(_IMPLEMENTATION_SLOT, newImplementation)
        }
        if (data.length > 0) {
            (bool ok,) = newImplementation.delegatecall(data);
            require(ok, "upgrade call failed");
        }
    }
}

/// @notice V1 vault, deployed behind VaultProxy. Shares are 1:1 with deposited assets.
contract UpgradeableVault is Initializable, UUPSUpgradeable {
    address public owner;
    IERC20 public asset;
    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;

    function initialize(IERC20 _asset, address _owner) external reinitializer(1) {
        asset = _asset;
        owner = _owner;
    }

    function deposit(uint256 amount) external {
        asset.transferFrom(msg.sender, address(this), amount);
        sharesOf[msg.sender] += amount;
        totalShares += amount;
    }

    function withdraw(uint256 shares) external {
        sharesOf[msg.sender] -= shares;
        totalShares -= shares;
        asset.transfer(msg.sender, shares);
    }

    function rescue(IERC20 token, address to, uint256 amount) external {
        require(msg.sender == owner, "not owner");
        require(token != asset, "cannot rescue asset");
        token.transfer(to, amount);
    }

    function _authorizeUpgrade(address) internal override {}
}

/// @notice V2 adds a withdrawal fee paid to the owner. Upgrade via
/// upgradeToAndCall(v2, abi.encodeCall(UpgradeableVaultV2.initializeV2, (feeBps))).
contract UpgradeableVaultV2 is Initializable, UUPSUpgradeable {
    uint256 public withdrawFeeBps;
    address public owner;
    IERC20 public asset;
    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;

    constructor() {
        _disableInitializers();
    }

    function initializeV2(uint256 feeBps) external reinitializer(2) {
        require(feeBps <= 1_000, "fee too high");
        withdrawFeeBps = feeBps;
    }

    function deposit(uint256 amount) external {
        asset.transferFrom(msg.sender, address(this), amount);
        sharesOf[msg.sender] += amount;
        totalShares += amount;
    }

    function withdraw(uint256 shares) external {
        sharesOf[msg.sender] -= shares;
        totalShares -= shares;
        uint256 fee = shares * withdrawFeeBps / 10_000;
        asset.transfer(owner, fee);
        asset.transfer(msg.sender, shares - fee);
    }

    function rescue(IERC20 token, address to, uint256 amount) external {
        require(msg.sender == owner, "not owner");
        require(token != asset, "cannot rescue asset");
        token.transfer(to, amount);
    }

    function _authorizeUpgrade(address) internal view override {
        require(msg.sender == owner, "not owner");
    }
}
