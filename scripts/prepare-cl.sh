#!/usr/bin/env bash

source ./scripts/util.sh
set -eu

mkdir -p $CONSENSUS_DIR
mkdir -p $BUILD_DIR

if ! test -e $BUILD_DIR/deposit; then
    echo "$BUILD_DIR/deposit not found. Downloading it from https://github.com/ethereum/staking-deposit-cli"

    curl -s -L -o $ROOT/deposit.tar.gz "https://github.com/ethereum/staking-deposit-cli/releases/download/v2.3.0/staking_deposit-cli-76ed782-linux-amd64.tar.gz"
    tar xf $ROOT/deposit.tar.gz -C $ROOT

    mv $ROOT/staking_deposit-cli-76ed782-linux-amd64/deposit $BUILD_DIR/deposit
    rm -rf $ROOT/staking_deposit-cli-76ed782-linux-amd64 $ROOT/deposit.tar.gz

    echo "$BUILD_DIR/deposit downloaded"
fi

validator_count=0
if test -e $BUILD_DIR/validator_keys; then
    # Check how many validators we have already generated
    validator_count=$(find $BUILD_DIR/validator_keys -name "keystore*" -print | wc -l)
fi

if test $validator_count -lt $VALIDATOR_COUNT; then
    echo "Generating the credentials for all of $VALIDATOR_COUNT validators at $BUILD_DIR/validator_keys"

    # Generate only for the remaining validators
    # We use kiln because we have the same GENESIS_FORK_VERSION which is 0x70000069
    $BUILD_DIR/deposit \
        --language english \
        --non_interactive \
        existing-mnemonic \
        --num_validators $(expr $VALIDATOR_COUNT - $validator_count)\
        --mnemonic="abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about" \
        --validator_start_index $validator_count \
        --chain kiln \
        --keystore_password $(cat $ROOT/password) \
        --folder $BUILD_DIR

    echo "Done generating the credentials"
fi

if ! test -e ./web3/node_modules; then
    echo "The package ./web3 doesn't have node modules installed yet. Installing the node modules now"
    npm --prefix ./web3 install >/dev/null 2>/dev/null
    echo "Node modules are already installed"
fi

# Use the signing node as a node to deploy the deposit contract
env="NODE_PATH=$(realpath ./web3/node_modules)"
args="$(realpath ./web3/src/deploy-deposit-contract.js) \
--endpoint http://localhost:$SIGNER_HTTP_PORT \
--file $(realpath ./assets/deposit-contract.json) \
--address-out $(realpath $ROOT/deposit-address) \
--block-out $(realpath $CONSENSUS_DIR/deploy_block.txt)"
yq -i ".hosts.signernode.processes += { \
    \"path\": \"node\", \
    \"environment\": \"$env\", \
    \"args\": \"$args\", \
    \"start_time\": $DEPLOY_DEPOSIT_CONTRACT_STARTTIME \
}" $SHADOW_CONFIG_FILE
log_shadow_config "the deposit contract deployment job of the \"signer\" node"

# Select the validator
mkdir -p $CONSENSUS_DIR/validator_keys
NODE_PATH=./web3/node_modules node ./web3/src/distribute-validators.js \
    --nc $NODE_COUNT \
    --vc $VALIDATOR_COUNT \
    -d $BUILD_DIR/validator_keys \
    -o $CONSENSUS_DIR/validator_keys \
    > $ROOT/deposit-data.json

# Send the deposits to the deposit contract
env="NODE_PATH=$(realpath ./web3/node_modules)"
args="$(realpath ./web3/src/transfer-deposit.js) \
--endpoint http://localhost:$SIGNER_HTTP_PORT \
--address-file $(realpath $ROOT/deposit-address) \
--contract-file $(realpath ./assets/deposit-contract.json) \
--deposit-file $(realpath $ROOT/deposit-data.json)"
yq -i ".hosts.signernode.processes += { \
    \"path\": \"node\", \
    \"environment\": \"$env\", \
    \"args\": \"$args\", \
    \"start_time\": $TRANSFER_DEPOSIT_STARTTIME \
}" $SHADOW_CONFIG_FILE
log_shadow_config "the deposit transfer job of the \"signer\" node"

cp $CONFIG_TEMPLATE_FILE $CONFIG_FILE
echo "PRESET_BASE: \"$PRESET_BASE\"" >> $CONFIG_FILE
echo "TERMINAL_TOTAL_DIFFICULTY: \"$TERMINAL_TOTAL_DIFFICULTY\"" >> $CONFIG_FILE
echo "MIN_GENESIS_ACTIVE_VALIDATOR_COUNT: \"$VALIDATOR_COUNT\"" >> $CONFIG_FILE
# 946684800 is January 1, 2000 12:00:00 AM which is the hard-coded start time of Shadow
echo "MIN_GENESIS_TIME: \"$(expr 946684800 + $GENESIS_DELAY)\"" >> $CONFIG_FILE
echo "GENESIS_DELAY: \"$GENESIS_DELAY\"" >> $CONFIG_FILE
echo "GENESIS_FORK_VERSION: \"$GENESIS_FORK_VERSION\"" >> $CONFIG_FILE

echo "DEPOSIT_CHAIN_ID: \"$NETWORK_ID\"" >> $CONFIG_FILE
echo "DEPOSIT_NETWORK_ID: \"$NETWORK_ID\"" >> $CONFIG_FILE

echo "SECONDS_PER_SLOT: \"$SECONDS_PER_SLOT\"" >> $CONFIG_FILE
echo "SECONDS_PER_ETH1_BLOCK: \"$SECONDS_PER_ETH1_BLOCK\"" >> $CONFIG_FILE

echo "ALTAIR_FORK_EPOCH: \"$ALTAIR_FORK_EPOCH\"" >> $CONFIG_FILE
echo "BELLATRIX_FORK_EPOCH: \"$BELLATRIX_FORK_EPOCH\"" >> $CONFIG_FILE

echo "Generated $CONFIG_FILE"

# Fill the contract address in the config file
env="NODE_PATH=$(realpath ./web3/node_modules)"
args="$(realpath ./web3/src/fill-lighthouse-config.js) \
--address-file $(realpath $ROOT/deposit-address) \
--config-file $(realpath $CONFIG_FILE)"
yq -i ".hosts.signernode.processes += { \
    \"path\": \"node\", \
    \"environment\": \"$env\", \
    \"args\": \"$args\", \
    \"start_time\": $FILL_LIGHTHOUSE_CONFIG_STARTTIME \
}" $SHADOW_CONFIG_FILE
log_shadow_config "the lighthouse config file filling job of the \"signer\" node"

args="eth1-genesis \
--spec $PRESET_BASE \
--eth1-endpoints http://localhost:$SIGNER_HTTP_PORT \
--testnet-dir $(realpath $CONSENSUS_DIR)
"
yq -i ".hosts.signernode.processes += { \
    \"path\": \"lcli\", \
    \"args\": \"$args\", \
    \"start_time\": $BEACON_GENESIS_STARTTIME \
}" $SHADOW_CONFIG_FILE
log_shadow_config "the beacon genesis generation job of the \"signer\" node"

lcli \
    generate-bootnode-enr \
    --ip $BOOTNODE_IP \
    --udp-port $CL_BOOTNODE_PORT \
    --tcp-port $CL_BOOTNODE_PORT \
    --genesis-fork-version $GENESIS_FORK_VERSION \
    --output-dir $CL_BOOTNODE_DIR

bootnode_enr=$(cat $CL_BOOTNODE_DIR/enr.dat)
echo "- $bootnode_enr" > $CONSENSUS_DIR/boot_enr.yaml
echo "Generated $CONSENSUS_DIR/boot_enr.yaml"

# Run "lighthouse account validator import" for each node
for (( node=1; node<=$NODE_COUNT; node++ )); do
    cl_data_dir $node
    mkdir -p $cl_data_dir
    args="\
--testnet-dir $(realpath $CONSENSUS_DIR) \
account validator import \
--directory $(realpath $CONSENSUS_DIR/validator_keys/node$node) \
--datadir $(realpath $cl_data_dir) \
--password-file $(realpath $ROOT/password) \
--reuse-password
"
    yq -i ".hosts.node$node.processes += { \
        \"path\": \"$LIGHTHOUSE_CMD\", \
        \"args\": \"$args\", \
        \"start_time\": $LIGHTHOUSE_VALIDATOR_IMPORT_STARTTIME \
    }" $SHADOW_CONFIG_FILE
    log_shadow_config "the lighthouse account validator import of the node #$node"
done

# The "lighthouse boot_node" process for the bootnode
# --disable-packet-filter is necessary because it's involed in rate limiting and nodes per IP limit
# See https://github.com/sigp/discv5/blob/v0.1.0/src/socket/filter/mod.rs#L149-L186
args="\
--testnet-dir $(realpath $CONSENSUS_DIR) \
boot_node \
--port $CL_BOOTNODE_PORT \
--disable-packet-filter \
--network-dir $(realpath $CL_BOOTNODE_DIR)
"
yq -i ".hosts.bootnode.processes += { \
    \"path\": \"$LIGHTHOUSE_CMD\", \
    \"args\": \"$args\", \
    \"start_time\": $LIGHTHOUSE_BOOT_NODE_STARTTIME \
}" $SHADOW_CONFIG_FILE
log_shadow_config "the lighthouse bootnode"

# The lighthouse beacon node process for each node
for (( node=1; node<=$NODE_COUNT; node++ )); do
    cl_data_dir $node
    el_data_dir $node
    node_ip $node
    env="LD_LIBRARY_PATH=$(realpath ~/dest/lib64)"
    # --disable-packet-filter is necessary because it's involed in rate limiting and nodes per IP limit
    # See https://github.com/sigp/discv5/blob/v0.1.0/src/socket/filter/mod.rs#L149-L186
    args="\
--testnet-dir $(realpath $CONSENSUS_DIR) \
beacon_node \
--datadir $(realpath $cl_data_dir) \
--execution-endpoint http://localhost:$EL_NODE_RPC_PORT \
--execution-jwt $(realpath $el_data_dir/geth/jwtsecret) \
--enable-private-discovery \
--staking \
--enr-address $ip \
--enr-udp-port $CL_BEACON_NODE_PORT \
--enr-tcp-port $CL_BEACON_NODE_PORT \
--port $CL_BEACON_NODE_PORT \
--http \
--http-port $CL_BEACON_NODE_HTTP_PORT \
--disable-packet-filter
"
    yq -i ".hosts.node$node.processes += { \
        \"path\": \"$LIGHTHOUSE_CMD\", \
        \"environment\": \"$env\", \
        \"args\": \"$args\", \
        \"start_time\": $LIGHTHOUSE_BEACON_NODE_STARTTIME \
    }" $SHADOW_CONFIG_FILE
    log_shadow_config "the lighthouse beacon node process of the node #$node"
done

# The lighthouse validator client process for each node
for (( node=1; node<=$NODE_COUNT; node++ )); do
    cl_data_dir $node
    el_data_dir $node
    args="\
--testnet-dir $(realpath $CONSENSUS_DIR) \
validator_client \
--datadir $(realpath $cl_data_dir) \
--init-slashing-protection \
--beacon-nodes http://localhost:$CL_BEACON_NODE_HTTP_PORT \
--suggested-fee-recipient $(cat $el_data_dir/address)
"
    yq -i ".hosts.node$node.processes += { \
        \"path\": \"$LIGHTHOUSE_CMD\", \
        \"args\": \"$args\", \
        \"start_time\": $LIGHTHOUSE_VALIDATOR_CLIENT_STARTTIME \
    }" $SHADOW_CONFIG_FILE
    log_shadow_config "the lighthouse validator client process of the node #$node"
done
