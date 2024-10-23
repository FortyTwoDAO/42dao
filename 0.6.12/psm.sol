// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.6.12;

import { BlcJoinAbstract } from "./lib/BlcJoinAbstract.sol";
import { BlcAbstract } from "./lib/BlcAbstract.sol";
import { VatAbstract } from "./lib/VatAbstract.sol";

interface AuthGemJoinAbstract {
    function dec() external view returns (uint256);
    function vat() external view returns (address);
    function ilk() external view returns (bytes32);
    function join(address, uint256, address) external;
    function exit(address, uint256) external;
}

// Peg Stability Module
// Allows anyone to go between Blc and the Gem by pooling the liquidity
// An optional fee is charged for incoming and outgoing transfers

contract DssPsm {

    // --- Auth ---
    mapping (address => uint256) public wards;
    function rely(address usr) external auth { wards[usr] = 1; emit Rely(usr); }
    function deny(address usr) external auth { wards[usr] = 0; emit Deny(usr); }
    modifier auth { require(wards[msg.sender] == 1, "DssPsm/not-authorized"); _; }

    VatAbstract immutable public vat;
    AuthGemJoinAbstract immutable public gemJoin;
    BlcAbstract immutable public blc;
    BlcJoinAbstract immutable public blcJoin;
    bytes32 immutable public ilk;
    address public feeCollector;

    uint256 immutable internal to18ConversionFactor;

    uint256 public tin;         // toll in [wad]
    uint256 public tout;        // toll out [wad]

    uint256 public constant ONE_DAY = uint(86400);
    uint256 public hop = ONE_DAY;

    uint256 public today;
    uint256 public todayAmount;
    uint256 public limitBaseAmount;

    uint256 public updateBaseRate;
    uint256 public limitRate;

    // --- Events ---
    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event File(bytes32 indexed what, uint256 data);
    event SellGem(address indexed owner, uint256 value, uint256 fee);
    event BuyGem(address indexed owner, uint256 value, uint256 fee);

    // --- Init ---
    constructor(address gemJoin_, address blcJoin_, address feeCollector_) public {
        wards[msg.sender] = 1;
        emit Rely(msg.sender);
        AuthGemJoinAbstract gemJoin__ = gemJoin = AuthGemJoinAbstract(gemJoin_);
        BlcJoinAbstract blcJoin__ = blcJoin = BlcJoinAbstract(blcJoin_);
        VatAbstract vat__ = vat = VatAbstract(address(gemJoin__.vat()));
        BlcAbstract blc__ = blc = BlcAbstract(address(blcJoin__.blc()));
        ilk = gemJoin__.ilk();
        feeCollector = feeCollector_;
        to18ConversionFactor = 10 ** (18 - gemJoin__.dec());
        blc__.approve(blcJoin_, type(uint256).max);
        vat__.hope(blcJoin_);
    }

    // --- Math ---
    uint256 constant WAD = 10 ** 18;
    uint256 constant RAY = 10 ** 27;
    function add(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x + y) >= x, "DssPsm/add-overflow");
    }
    function sub(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x - y) <= x, "DssPsm/sub-underflow");
    }
    function mul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require(y == 0 || (z = x * y) / y == x, "DssPsm/mul-overflow");
    }

    // --- Administration ---
    function file(bytes32 what, uint256 data) external auth {
        if (what == "tin") tin = data;
        else if (what == "tout") tout = data;
        else if (what == "updateBaseRate") updateBaseRate = data;
        else if (what == "limitRate") limitRate = data;
        else revert("DssPsm/file-unrecognized-param");

        emit File(what, data);
    }
    function file(bytes32 what, address data) external auth {
        if (what == "feeCollector") feeCollector = data;
        else revert("DssPsm/file-unrecognized-param");
    }

    // hope can be used to transfer control of the PSM vault to another contract
    // This can be used to upgrade the contract
    function hope(address usr) external auth {
        vat.hope(usr);
    }
    function nope(address usr) external auth {
        vat.nope(usr);
    }

    function era() internal view returns (uint) {
        return block.timestamp;
    }

    function prev(uint ts) internal view returns (uint) {
        require(hop != 0, "DssPsm/hop-is-zero");
        return ts - (ts % hop);
    }

    function newDay() public view returns (bool ok) {
        return era() >= add(today, hop);
    }

    // --- Primary Functions ---
    function sellGem(address usr, uint256 gemAmt) external {
        uint256 gemAmt18 = mul(gemAmt, to18ConversionFactor);
        uint256 fee = mul(gemAmt18, tin) / WAD;
        uint256 blcAmt = sub(gemAmt18, fee);
        gemJoin.join(address(this), gemAmt, msg.sender);
        vat.frob(ilk, address(this), address(this), address(this), int256(gemAmt18), int256(gemAmt18));
        vat.move(address(this), feeCollector, mul(fee, RAY));
        blcJoin.exit(usr, blcAmt);

        emit SellGem(usr, gemAmt, fee);
    }

    function buyGem(address usr, uint256 gemAmt) external {
        uint256 gemAmt18 = mul(gemAmt, to18ConversionFactor);

        (uint256 curBalance,) = vat.urns(ilk, address(this));
        if (newDay()) {
            today = prev(era());
            todayAmount = 0;
            limitBaseAmount = curBalance;
        } else if (mul(limitBaseAmount, updateBaseRate) / WAD <= curBalance) {
            limitBaseAmount = curBalance;
        }

        todayAmount = add(todayAmount, gemAmt18);
        uint256 limitAmount = getBuyLimitAmount();
        if (limitAmount > 0) {
            require(todayAmount <= limitAmount, "DssPsm/over-the-limit");
        }

        uint256 fee = mul(gemAmt18, tout) / WAD;
        uint256 blcAmt = add(gemAmt18, fee);
        require(blc.transferFrom(msg.sender, address(this), blcAmt), "DssPsm/failed-transfer");
        blcJoin.join(address(this), blcAmt);
        vat.frob(ilk, address(this), address(this), address(this), -int256(gemAmt18), -int256(gemAmt18));
        gemJoin.exit(usr, gemAmt);
        vat.move(address(this), feeCollector, mul(fee, RAY));

        emit BuyGem(usr, gemAmt, fee);
    }

    function getBuyLimitAmount() public view returns (uint) {
        return limitRate > 0 ? mul(limitBaseAmount, limitRate) / WAD : 0;
    }
}