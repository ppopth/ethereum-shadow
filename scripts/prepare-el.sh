#!/usr/bin/env bash

source ./scripts/util.sh
set -eu

mkdir -p $EXECUTION_DIR

genesis=$(cat $GENESIS_TEMPLATE_FILE)
next=1
for (( node=1; node<=$NODE_COUNT; node++ )); do
    el_data_dir $node
    datadir=$el_data_dir
    mkdir -p $datadir

    # Generate a new account for each geth node
    $GETH_CMD --datadir $datadir account new --password $ROOT/password 2>/dev/null > $datadir/account_new.log &
    if test $(expr $node % $PARALLELISM) -eq 0 || test $node -eq $NODE_COUNT; then
        wait

        for (( ; next<=$node; next++ )); do
            el_data_dir $next
            datadir=$el_data_dir
            address=$(cat $datadir/account_new.log | grep -o "0x[0-9a-fA-F]*")
            echo "Generated an account with address $address for geth node $next and saved it at $datadir"
            echo $address > $datadir/address

            # Add the account into the genesis state
            alloc=$(echo $genesis | jq ".alloc + { \"${address:2}\": { \"balance\": \"$INITIAL_BALANCE\" } }")
            genesis=$(echo $genesis | jq ". + { \"alloc\": $alloc }")
        done
    fi
done

# Generate a new account for the signer geth node
address=$($GETH_CMD --datadir $SIGNER_EL_DATADIR account new --password $ROOT/password 2>/dev/null | grep -o "0x[0-9a-fA-F]*")
echo "Generated an account with address $address for geth node 'signer' and saved it at $SIGNER_EL_DATADIR"
echo $address > $SIGNER_EL_DATADIR/address
# Add the account into the genesis state
alloc=$(echo $genesis | jq ".alloc + { \"${address:2}\": { \"balance\": \"$INITIAL_BALANCE\" } }")
genesis=$(echo $genesis | jq ". + { \"alloc\": $alloc }")

# Add the extradata
zeroes() {
    for i in $(seq $1); do
        echo -n "0"
    done
}
address=$(cat $SIGNER_EL_DATADIR/address)
extra_data="0x$(zeroes 64)${address:2}$(zeroes 130)"
genesis=$(echo $genesis | jq ". + { \"extradata\": \"$extra_data\" }")

# Add the terminal total difficulty
config=$(echo $genesis | jq ".config + { \"chainId\": "$NETWORK_ID", \"terminalTotalDifficulty\": "$TERMINAL_TOTAL_DIFFICULTY", \"clique\": { \"period\": "$SECONDS_PER_ETH1_BLOCK", \"epoch\": 30000 } }")
genesis=$(echo $genesis | jq ". + { \"config\": $config }")

# Generate the genesis state
echo $genesis > $GENESIS_FILE
echo "Generated $GENESIS_FILE"

# Initialize the geth nodes' directories
for (( node=1; node<=$NODE_COUNT; node++ )); do
    el_data_dir $node
    datadir=$el_data_dir

    $GETH_CMD init --datadir $datadir $GENESIS_FILE 2>/dev/null
    echo "Initialized the data directory $datadir with $GENESIS_FILE"
done

$GETH_CMD init --datadir $SIGNER_EL_DATADIR $GENESIS_FILE 2>/dev/null
echo "Initialized the data directory $SIGNER_EL_DATADIR with $GENESIS_FILE"

# Set the IP address for the bootnode
yq -i ".hosts.bootnode.ip_addr = \"$BOOTNODE_IP\"" $SHADOW_CONFIG_FILE
# The "bootnode" process for the bootnode
args="-nodekey $(realpath ./assets/execution/boot.key) -verbosity 5 -addr :$EL_BOOTNODE_PORT"
yq -i ".hosts.bootnode.processes += { \"path\": \"bootnode\", \"args\": \"$args\" }" $SHADOW_CONFIG_FILE
log_shadow_config "the geth bootnode"

boot_enode="$(cat ./assets/execution/boot.enode)@$BOOTNODE_IP:0?discport=$EL_BOOTNODE_PORT"

# The geth process in the signer node
address=$(cat $SIGNER_EL_DATADIR/address)
args="\
--datadir $(realpath $SIGNER_EL_DATADIR) \
--port $SIGNER_PORT \
--http \
--http.port $SIGNER_HTTP_PORT \
--allow-insecure-unlock \
--bootnodes $boot_enode \
--networkid $NETWORK_ID \
--nat extip:$SIGNER_IP \
--ipcdisable \
--unlock $address \
--password $(realpath $ROOT/password) \
--mine
"
yq -i ".hosts.signernode.processes += { \"path\": \"$GETH_CMD\", \"args\": \"$args\" }" $SHADOW_CONFIG_FILE
yq -i ".hosts.signernode.ip_addr = \"$SIGNER_IP\"" $SHADOW_CONFIG_FILE
log_shadow_config "the geth process of the \"signer\" node"

# The geth process for each node
for (( node=1; node<=$NODE_COUNT; node++ )); do
    el_data_dir $node
    address=$(cat $el_data_dir/address)
    node_ip $node

    args="\
--datadir $(realpath $el_data_dir) \
--authrpc.port $EL_NODE_RPC_PORT \
--port $EL_NODE_PORT \
--bootnodes $boot_enode \
--networkid $NETWORK_ID \
--nat extip:$ip \
--ipcdisable \
--unlock $address \
--password $(realpath $ROOT/password)
"
    yq -i ".hosts.node$node.processes += { \"path\": \"$GETH_CMD\", \"args\": \"$args\" }" $SHADOW_CONFIG_FILE
    log_shadow_config "the geth process of the node #$node"
done
