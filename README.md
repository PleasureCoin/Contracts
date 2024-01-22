# PleasureCoin Contracts

Developing Solidity Contracts

## Recommended IDE Setup

I use webstorm IDE, any text editor should do the work.

## Customize configuration

Create a hardhat.config.js

## Project Setup

Do not update ethers > Version 5

```sh
npm install
```

### Compile

```sh
npx hardhat clean

npx hardhat compile
```

### Deployment

```sh
npx hardhat run --network mumbai .\scripts\deployment.js

npx hardhat verify --network mumbai [last contract]
```
