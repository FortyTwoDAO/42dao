pragma solidity =0.5.12;

import "./lib/lib.sol";

contract GemLike {
    function decimals() public view returns (uint);
    function transfer(address,uint) external returns (bool);
    function transferFrom(address,address,uint) external returns (bool);
}

contract DSTokenLike {
    function mint(address,uint) external;
    function burn(address,uint) external;
}

contract VatLike {
    function slip(bytes32,address,int) external;
    function move(address,address,uint) external;
}

contract GemJoin is LibNote {
    // --- Auth ---
    mapping (address => uint) public wards;
    function rely(address usr) external note auth { wards[usr] = 1; }
    function deny(address usr) external note auth { wards[usr] = 0; }
    modifier auth {
        require(wards[msg.sender] == 1, "GemJoin/not-authorized");
        _;
    }
    function mul(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x);
    }

    VatLike public vat;
    bytes32 public ilk;
    GemLike public gem;
    uint    public dec;
    uint    public live;  // Access Flag

    constructor(address vat_, bytes32 ilk_, address gem_) public {
        wards[msg.sender] = 1;
        live = 1;
        vat = VatLike(vat_);
        ilk = ilk_;
        gem = GemLike(gem_);
        dec = gem.decimals();
    }
    function cage() external note auth {
        live = 0;
    }
    function join(address usr, uint wad) external note {
        uint256 wad18 = convertTo18(wad);
        require(live == 1, "GemJoin/not-live");
        require(int(wad18) >= 0, "GemJoin/overflow");
        vat.slip(ilk, usr, int(wad18));
        require(gem.transferFrom(msg.sender, address(this), wad), "GemJoin/failed-transfer");
    }
    function exit(address usr, uint wad) external note {
        uint256 wad18 = convertTo18(wad);
        require(wad18 <= 2 ** 255, "GemJoin/overflow");
        vat.slip(ilk, msg.sender, -int(wad18));
        require(gem.transfer(usr, wad), "GemJoin/failed-transfer");
    }

    function convertTo18(uint256 amt) internal returns (uint256 wad) {
        // For those collaterals that have less than 18 decimals precision we need to do the conversion before passing to frob function
        // Adapters will automatically handle the difference of precision
        wad = mul(
            amt,
            10 ** (18 - dec)
        );
    }
}