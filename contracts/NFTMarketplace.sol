// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.0.0
pragma solidity ^0.8.27;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

contract NFTMarketplace is
    ERC721,
    ERC721URIStorage,
    Ownable,
    ReentrancyGuard,
    EIP712
{
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    uint256 private _nextTokenId;
    uint256 private _platformFee = 5;
    uint256 private _royalties = 5;

    bytes32 private constant VOUCHER_TYPEHASH =
        keccak256("NFTVoucher(address creator,string uri,uint256 price)");

    struct NFTItem {
        uint256 id;
        address creator;
        address currentOwner;
        uint256 price;
        bool isListed;
        uint256 createdAt;
    }

    struct NFTVoucher {
        address creator;
        string uri;
        uint256 price;
        uint256 expiry;
    }

    mapping(uint256 => NFTItem) public idToNFTItem;
    mapping(bytes32 => bool) public usedSignatures;

    event NFTTransferred(
        address indexed from,
        address indexed to,
        uint256 indexed tokenId
    );

    modifier nftExists(uint256 tokenID) {
        require(_ownerOf(tokenID) != address(0), "NFT does not exist");
        _;
    }

    modifier nftDoesNotExist(uint256 tokenID) {
        require(_ownerOf(tokenID) == address(0), "NFT exists");
        _;
    }

    modifier isListed(uint256 tokenID) {
        require(idToNFTItem[tokenID].isListed, "NFT is not for sale");
        _;
    }

    modifier notListed(uint256 tokenID) {
        require(!idToNFTItem[tokenID].isListed, "NFT is still for sale");
        _;
    }

    modifier isOwner(uint256 tokenId) {
        require(ownerOf(tokenId) == msg.sender, "Not the token owner");
        _;
    }

    constructor(
        address initialOwner
    )
        ERC721("NFTMarketplace", "WMNFT")
        Ownable(initialOwner)
        EIP712("NFTMarketPlace", "1")
    {}

    function _hash(
        NFTVoucher calldata voucher
    ) internal view returns (bytes32) {
        return
            _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        VOUCHER_TYPEHASH,
                        voucher.creator,
                        keccak256(bytes(voucher.uri)),
                        voucher.price
                    )
                )
            );
    }

    function lazyMint(
        NFTVoucher calldata voucher,
        bytes calldata signature
    ) external payable {
        bytes32 sigHash = keccak256(signature);

        require(!usedSignatures[sigHash], "Signature already used");
        require(msg.value >= voucher.price, "Insufficient payment");
        require(block.timestamp <= voucher.expiry, "Voucher expired");

        bytes32 digest = _hash(voucher);
        address signer = ECDSA.recover(digest, signature);

        require(signer == voucher.creator, "Invalid signature");

        usedSignatures[sigHash] = true;

        _nextTokenId++;
        uint256 tokenId = _nextTokenId;

        _safeMint(msg.sender, tokenId);
        _setTokenURI(tokenId, voucher.uri);

        idToNFTItem[tokenId].creator = voucher.creator;

        (bool sent, ) = payable(voucher.creator).call{value: msg.value}("");
        require(sent, "Payment failed");
    }

    function listNFT(
        uint256 tokenID,
        uint256 price
    ) public isOwner(tokenID) nftExists(tokenID) notListed(tokenID) {
        require(price > 0, "Price must be greater than 0");

        NFTItem storage nft = idToNFTItem[tokenID];

        if (nft.id == 0) {
            idToNFTItem[tokenID] = NFTItem({
                id: tokenID,
                currentOwner: ownerOf(tokenID),
                price: price,
                isListed: true,
                createdAt: block.timestamp,
                creator: idToNFTItem[tokenID].creator
            });
        } else {
            nft.isListed = true;
            nft.price = price;
        }
    }

    function unlistNFT(
        uint256 tokenID
    ) public isOwner(tokenID) nftExists(tokenID) isListed(tokenID) {
        idToNFTItem[tokenID].isListed = false;
    }

    function transferNFT(address to, uint256 tokenID) public {
        address owner = _ownerOf(tokenID);
        _checkAuthorized(owner, msg.sender, tokenID);

        _transfer(owner, to, tokenID);

        idToNFTItem[tokenID].isListed = false;

        emit NFTTransferred(owner, to, tokenID);
    }

    function buyNFT(
        uint256 tokenID
    ) public payable nonReentrant nftExists(tokenID) isListed(tokenID) {
        NFTItem storage nft = idToNFTItem[tokenID];
        uint256 price = nft.price;
        address seller = ownerOf(tokenID);

        uint256 royalty = (price * _royalties) / 100;
        uint256 fee = (price * _platformFee) / 100;
        uint256 sellerGets = price - royalty - fee;

        require(seller != msg.sender, "You already own this NFT");
        require(msg.value >= price, "Incorrect amount sent");

        _transfer(seller, msg.sender, tokenID);

        (bool sellerPayment, ) = payable(seller).call{value: sellerGets}("");
        require(sellerPayment, "Seller payment transfer failed");

        (bool contractPayment, ) = payable(owner()).call{value: fee}("");
        require(contractPayment, "Contract payment transfer failed");

        if (seller != nft.creator) {
            (bool royaltiesPayment, ) = payable(nft.creator).call{
                value: royalty
            }("");
            require(royaltiesPayment, "Royalties transfer failed");
        }

        uint256 refund = msg.value - price;

        if (refund > 0) {
            (bool refunded, ) = payable(msg.sender).call{value: refund}("");
            require(refunded, "Refund failed");
        }

        nft.isListed = false;
        nft.currentOwner = msg.sender;
    }

    function getAllNFTs() public view returns (NFTItem[] memory) {
        uint256 total = _nextTokenId;
        uint256 validCount = 0;

        for (uint256 i = 0; i < total; i++) {
            if (idToNFTItem[i + 1].id != 0) {
                validCount++;
            }
        }

        NFTItem[] memory items = new NFTItem[](validCount);
        uint256 count = 0;

        for (uint256 i = 0; i < total; i++) {
            NFTItem memory nft = idToNFTItem[i + 1];
            if (nft.id != 0) {
                items[count] = NFTItem({
                    id: nft.id,
                    creator: nft.creator,
                    currentOwner: ownerOf(nft.id),
                    price: nft.price,
                    isListed: nft.isListed,
                    createdAt: nft.createdAt
                });
                count++;
            }
        }

        return items;
    }

    function withdraw() external onlyOwner {
        (bool sent, ) = payable(owner()).call{value: address(this).balance}("");
        require(sent, "Withdraw failed");
    }

    receive() external payable {}
    fallback() external payable {}

    // The following functions are overrides required by Solidity.

    function tokenURI(
        uint256 tokenId
    ) public view override(ERC721, ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC721, ERC721URIStorage) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
