const Pool = artifacts.require('Pool');
const Factory = artifacts.require('Factory');
const TToken = artifacts.require('TToken');
const TConstantOracle = artifacts.require('TConstantOracle');
const truffleAssert = require('truffle-assertions');

contract('Factory', async (accounts) => {

	let now = 1641893000;

    const admin = accounts[0];
    const nonAdmin = accounts[1];
    const user2 = accounts[2];
    const { toWei } = web3.utils;
    const { fromWei } = web3.utils;
    const { hexToUtf8 } = web3.utils;

    const MAX = web3.utils.toTwosComplement(-1);

    describe('Factory', () => {
        let factory;
        let pool;
        let POOL;
        let WETH;
        let DAI;
        let weth;
        let dai;
        let wethOracle;
        let daiOracle;

        before(async () => {
            factory = await Factory.deployed();
            weth = await TToken.new('Wrapped Ether', 'WETH', 18);
            dai = await TToken.new('Dai Stablecoin', 'DAI', 18);

            WETH = weth.address;
            DAI = dai.address;

            // admin balances
            await weth.mint(admin, toWei('5'));
            await dai.mint(admin, toWei('200'));

            // nonAdmin balances
            await weth.mint(nonAdmin, toWei('1'), { from: admin });
            await dai.mint(nonAdmin, toWei('50'), { from: admin });

            POOL = await factory.newPool.call(); // this works fine in clean room
            await factory.newPool();
            pool = await Pool.at(POOL);

            await weth.approve(POOL, MAX);
            await dai.approve(POOL, MAX);

            await weth.approve(POOL, MAX, { from: nonAdmin });
            await dai.approve(POOL, MAX, { from: nonAdmin });
        });

        it('isPool on non pool returns false', async () => {
            const isPool = await factory.isPool(admin);
            assert.isFalse(isPool);
        });

        it('isPool on pool returns true', async () => {
            const isPool = await factory.isPool(POOL);
            assert.isTrue(isPool);
        });

        it('fails nonAdmin calls collect', async () => {
            await truffleAssert.reverts(factory.collect(nonAdmin, { from: nonAdmin }), 'ERR_NOT_SWAAPLABS');
        });

        it('admin collects fees', async () => {
			wethOracle = await TConstantOracle.new(40, now);
			daiOracle = await TConstantOracle.new(1, now);
            await pool.bindMMM(WETH, toWei('5'), toWei('5'), wethOracle.address);
            await pool.bindMMM(DAI, toWei('200'), toWei('5'), daiOracle.address);

            await pool.finalize();

            await pool.joinPool(toWei('10'), [MAX, MAX], { from: nonAdmin });
            await pool.exitPool(toWei('10'), [toWei('0'), toWei('0')], { from: nonAdmin });

            // Exit fee = 0 so this wont do anything
            await factory.collect(POOL);

            const adminBalance = await pool.balanceOf(admin);
            assert.equal(fromWei(adminBalance), '100');
        });

        it('nonadmin cant set swaaplabs address', async () => {
            await truffleAssert.reverts(factory.setSwaapLabs(nonAdmin, { from: nonAdmin }), 'ERR_NOT_SWAAPLABS');
        });

        it('admin changes swaaplabs address', async () => {
            await factory.setSwaapLabs(user2);
            const blab = await factory.getSwaapLabs();
            assert.equal(blab, user2);
        });
    });
});
