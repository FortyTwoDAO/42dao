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
        require(live == 1, "GemJoin/not-live");
        require(int(wad) >= 0, "GemJoin/overflow");
        vat.slip(ilk, usr, int(convertTo18(wad)));
        require(gem.transferFrom(msg.sender, address(this), wad), "GemJoin/failed-transfer");
    }
    function exit(address usr, uint wad) external note {
        require(wad <= 2 ** 255, "GemJoin/overflow");
        vat.slip(ilk, msg.sender, -int(convertTo18(wad)));
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

contract ETHJoin is LibNote {
    // --- Auth ---
    mapping (address => uint) public wards;
    function rely(address usr) external note auth { wards[usr] = 1; }
    function deny(address usr) external note auth { wards[usr] = 0; }
    modifier auth {
        require(wards[msg.sender] == 1, "ETHJoin/not-authorized");
        _;
    }

    VatLike public vat;
    bytes32 public ilk;
    uint    public live;  // Access Flag

    constructor(address vat_, bytes32 ilk_) public {
        wards[msg.sender] = 1;
        live = 1;
        vat = VatLike(vat_);
        ilk = ilk_;
    }
    function cage() external note auth {
        live = 0;
    }
    function join(address usr) external payable note {
        require(live == 1, "ETHJoin/not-live");
        require(int(msg.value) >= 0, "ETHJoin/overflow");
        vat.slip(ilk, usr, int(msg.value));
    }
    function exit(address payable usr, uint wad) external note {
        require(int(wad) >= 0, "ETHJoin/overflow");
        vat.slip(ilk, msg.sender, -int(wad));
        usr.transfer(wad);
    }
}

contract BlcJoin is LibNote {
    // --- Auth ---
    mapping (address => uint) public wards;
    function rely(address usr) external note auth { wards[usr] = 1; }
    function deny(address usr) external note auth { wards[usr] = 0; }
    modifier auth {
        require(wards[msg.sender] == 1, "BlcJoin/not-authorized");
        _;
    }

    VatLike public vat;
    DSTokenLike public blc;
    uint    public live;  // Access Flag

    constructor(address vat_, address blc_) public {
        wards[msg.sender] = 1;
        live = 1;
        vat = VatLike(vat_);
        blc = DSTokenLike(blc_);
    }
    function cage() external note auth {
        live = 0;
    }
    uint constant ONE = 10 ** 27;
    function mul(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x);
    }
    function join(address usr, uint wad) external note {
        vat.move(address(this), usr, mul(ONE, wad));
        blc.burn(msg.sender, wad);
    }
    function exit(address usr, uint wad) external note {
        require(live == 1, "BlcJoin/not-live");
        vat.move(msg.sender, address(this), mul(ONE, wad));
        blc.mint(usr, wad);
    }
}