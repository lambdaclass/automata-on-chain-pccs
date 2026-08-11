$(eval CHAIN_ID := $(shell rex chain-id))
$(eval OWNER := $(shell rex address))

SOLC_FLAGS := --overwrite --optimize --via-ir

# src/ is kept byte-identical to upstream: imports resolve through these remappings
# (the same ones upstream lists in remappings.txt) instead of being rewritten to
# relative paths, so rebasing onto upstream touches no Solidity.
SOLC_REMAP := solady/=lib/solady/src/ @openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/
SOLC := solc $(SOLC_FLAGS) $(SOLC_REMAP)

# Deployed separately by the consumer (ethrex deploys it with the deterministic
# deployer from assets/p256.hex) and passed to every DAO as the P256 verifier.
P256_ADDR := 0xc2b78104907F722DABAc4C69f826a522B2754De4

# TCB evaluation data number the versioned DAOs are deployed under. A quote verified
# through the 1-argument verifyAndAttestOnChain resolves eval number 0 to whatever
# TcbEvalDao reports as `standard`, and PCCSRouter then looks the versioned DAOs up by
# that number, so this must match the standard number seeded into TcbEvalDao.
TCB_EVAL_NUMBER ?= 19

# Pinned dependency revisions. lib/ is gitignored, so these are the only record of
# what a deployment was built from. Both libraries reach the bytecode.
# Comments stay off the value lines: Make keeps whitespace before an inline `#`.
# openzeppelin v5.7.0
OPENZEPPELIN_REV = cab19933c33c2ad1d4c7a84864a3601dddfd16f3
# solady main tip, 23 commits past v0.1.26
SOLADY_REV = c251232428b668a073293eb04c6c288b19ad5728

# Clone if absent, then re-assert and verify the pin on every run, so a stale or
# half-checked-out lib/ is corrected rather than silently reused. `make clean` removes
# every pinned tree, for when a pin cannot be re-asserted in place.
define pin
	@test -d $(1)/.git || git clone -q $(2) $(1)
	@git -C $(1) cat-file -e "$(3)^{commit}" 2>/dev/null || git -C $(1) fetch -q --tags origin
	@git -c advice.detachedHead=false -C $(1) checkout -q --detach $(3)
	@test "$$(git -C $(1) rev-parse HEAD)" = "$(3)" || { echo "$(1): not at $(3)"; exit 1; }
endef

.PHONY: deps
deps:
	mkdir -p deployment
	$(call pin,lib/openzeppelin-contracts,https://github.com/OpenZeppelin/openzeppelin-contracts,$(OPENZEPPELIN_REV))
	$(call pin,lib/solady,https://github.com/vectorized/solady,$(SOLADY_REV))

# ---------------------------------------------------------------- compile

out/PCKHelper.bin: | deps
	$(SOLC) src/helpers/PCKHelper.sol --bin -o out/

out/X509CRLHelper.bin: | deps
	$(SOLC) src/helpers/X509CRLHelper.sol --bin -o out/

out/EnclaveIdentityHelper.bin: | deps
	$(SOLC) src/helpers/EnclaveIdentityHelper.sol --bin -o out/

out/FmspcTcbHelper.bin: | deps
	$(SOLC) src/helpers/FmspcTcbHelper.sol --bin -o out/

out/TcbEvalHelper.bin: | deps
	$(SOLC) src/helpers/TcbEvalHelper.sol --bin -o out/

out/AutomataDaoStorage.bin: | deps
	$(SOLC) src/automata_pccs/shared/AutomataDaoStorage.sol --bin -o out/

out/PccsDependencyConfig.bin: | deps
	$(SOLC) src/automata_pccs/shared/PccsDependencyConfig.sol --bin -o out/

out/AutomataPcsDao.bin: | deps
	$(SOLC) src/automata_pccs/AutomataPcsDao.sol --bin -o out/

out/AutomataPckDao.bin: | deps
	$(SOLC) src/automata_pccs/AutomataPckDao.sol --bin -o out/

out/AutomataTcbEvalDao.bin: | deps
	$(SOLC) src/automata_pccs/AutomataTcbEvalDao.sol --bin -o out/

out/AutomataEnclaveIdentityDaoVersioned.bin: | deps
	$(SOLC) src/automata_pccs/versioned/AutomataEnclaveIdentityDaoVersioned.sol --bin -o out/

out/AutomataFmspcTcbDaoVersioned.bin: | deps
	$(SOLC) src/automata_pccs/versioned/AutomataFmspcTcbDaoVersioned.sol --bin -o out/

.PHONY: build
build: out/PCKHelper.bin out/X509CRLHelper.bin out/EnclaveIdentityHelper.bin \
	out/FmspcTcbHelper.bin out/TcbEvalHelper.bin out/AutomataDaoStorage.bin \
	out/PccsDependencyConfig.bin out/AutomataPcsDao.bin out/AutomataPckDao.bin \
	out/AutomataTcbEvalDao.bin out/AutomataEnclaveIdentityDaoVersioned.bin \
	out/AutomataFmspcTcbDaoVersioned.bin

# ---------------------------------------------------------------- deploy
# Each address is written to deployment/<ContractName>, which is the interface the
# automata-dcap-attestation Makefile and ethrex's TDX deployer both read.

deploy-helpers: out/PCKHelper.bin out/X509CRLHelper.bin out/EnclaveIdentityHelper.bin out/FmspcTcbHelper.bin out/TcbEvalHelper.bin
	rex deploy --print-address $(shell cat out/PCKHelper.bin) 0 $(PRIVATE_KEY) > deployment/PCKHelper
	rex deploy --print-address $(shell cat out/X509CRLHelper.bin) 0 $(PRIVATE_KEY) > deployment/X509CRLHelper
	rex deploy --print-address $(shell cat out/EnclaveIdentityHelper.bin) 0 $(PRIVATE_KEY) > deployment/EnclaveIdentityHelper
	rex deploy --print-address $(shell cat out/FmspcTcbHelper.bin) 0 $(PRIVATE_KEY) > deployment/FmspcTcbHelper
	rex deploy --print-address $(shell cat out/TcbEvalHelper.bin) 0 $(PRIVATE_KEY) > deployment/TcbEvalHelper

deploy-storage: out/AutomataDaoStorage.bin out/PccsDependencyConfig.bin deploy-helpers
	rex deploy --print-address $(shell cat out/AutomataDaoStorage.bin) 0 $(PRIVATE_KEY) -- \
		"constructor(address)" $(OWNER) > deployment/AutomataDaoStorage
	rex deploy --print-address $(shell cat out/PccsDependencyConfig.bin) 0 $(PRIVATE_KEY) -- \
		"constructor(address)" $(OWNER) > deployment/PccsDependencyConfig

deploy-pcs: out/AutomataPcsDao.bin deploy-storage
	$(eval STORAGE_ADDR := $(shell cat deployment/AutomataDaoStorage))
	$(eval X509_ADDR := $(shell cat deployment/PCKHelper))
	$(eval X509_CRL_ADDR := $(shell cat deployment/X509CRLHelper))
	rex deploy --print-address $(shell cat out/AutomataPcsDao.bin) 0 $(PRIVATE_KEY) -- \
		"constructor(address,address,address,address)" \
		$(STORAGE_ADDR) $(P256_ADDR) $(X509_ADDR) $(X509_CRL_ADDR) \
		> deployment/AutomataPcsDao

deploy-pck: out/AutomataPckDao.bin deploy-pcs
	$(eval STORAGE_ADDR := $(shell cat deployment/AutomataDaoStorage))
	$(eval X509_ADDR := $(shell cat deployment/PCKHelper))
	$(eval X509_CRL_ADDR := $(shell cat deployment/X509CRLHelper))
	$(eval PCS_ADDR := $(shell cat deployment/AutomataPcsDao))
	rex deploy --print-address $(shell cat out/AutomataPckDao.bin) 0 $(PRIVATE_KEY) -- \
		"constructor(address,address,address,address,address)" \
		$(STORAGE_ADDR) $(P256_ADDR) $(PCS_ADDR) $(X509_ADDR) $(X509_CRL_ADDR) \
		> deployment/AutomataPckDao

deploy-tcb-eval-dao: out/AutomataTcbEvalDao.bin deploy-pcs
	$(eval STORAGE_ADDR := $(shell cat deployment/AutomataDaoStorage))
	$(eval DEPCONFIG_ADDR := $(shell cat deployment/PccsDependencyConfig))
	$(eval TCB_EVAL_HELPER_ADDR := $(shell cat deployment/TcbEvalHelper))
	$(eval X509_ADDR := $(shell cat deployment/PCKHelper))
	rex deploy --print-address $(shell cat out/AutomataTcbEvalDao.bin) 0 $(PRIVATE_KEY) -- \
		"constructor(address,address,address,address,address,address)" \
		$(STORAGE_ADDR) $(P256_ADDR) $(DEPCONFIG_ADDR) $(TCB_EVAL_HELPER_ADDR) $(X509_ADDR) $(OWNER) \
		> deployment/AutomataTcbEvalDao

deploy-id-dao: out/AutomataEnclaveIdentityDaoVersioned.bin deploy-pcs
	$(eval STORAGE_ADDR := $(shell cat deployment/AutomataDaoStorage))
	$(eval DEPCONFIG_ADDR := $(shell cat deployment/PccsDependencyConfig))
	$(eval ENCLAVE_HELPER_ADDR := $(shell cat deployment/EnclaveIdentityHelper))
	$(eval X509_ADDR := $(shell cat deployment/PCKHelper))
	rex deploy --print-address $(shell cat out/AutomataEnclaveIdentityDaoVersioned.bin) 0 $(PRIVATE_KEY) -- \
		"constructor(address,address,address,address,address,uint32)" \
		$(STORAGE_ADDR) $(P256_ADDR) $(DEPCONFIG_ADDR) $(ENCLAVE_HELPER_ADDR) $(X509_ADDR) $(OWNER) $(TCB_EVAL_NUMBER) \
		> deployment/AutomataEnclaveIdentityDao

deploy-fmspc-tcb-dao: out/AutomataFmspcTcbDaoVersioned.bin deploy-pcs
	$(eval STORAGE_ADDR := $(shell cat deployment/AutomataDaoStorage))
	$(eval FMSPC_HELPER_ADDR := $(shell cat deployment/FmspcTcbHelper))
	$(eval X509_ADDR := $(shell cat deployment/PCKHelper))
	$(eval X509_CRL_ADDR := $(shell cat deployment/X509CRLHelper))
	$(eval PCS_ADDR := $(shell cat deployment/AutomataPcsDao))
	rex deploy --print-address $(shell cat out/AutomataFmspcTcbDaoVersioned.bin) 0 $(PRIVATE_KEY) -- \
		"constructor(address,address,address,address,address,address,address,uint32)" \
		$(STORAGE_ADDR) $(P256_ADDR) $(PCS_ADDR) $(FMSPC_HELPER_ADDR) $(X509_ADDR) $(X509_CRL_ADDR) $(OWNER) $(TCB_EVAL_NUMBER) \
		> deployment/AutomataFmspcTcbDaoVersioned

# The versioned identity DAO is written to deployment/AutomataEnclaveIdentityDao (the
# name consumers already read) and the versioned TCB DAO additionally under the legacy
# name, so a consumer written against the pre-versioned layout keeps resolving.
deploy-and-configure: deploy-pck deploy-tcb-eval-dao deploy-id-dao deploy-fmspc-tcb-dao
	cp deployment/AutomataFmspcTcbDaoVersioned deployment/AutomataFmspcTcbDao
	$(eval STORAGE_ADDR := $(shell cat deployment/AutomataDaoStorage))
	$(eval DEPCONFIG_ADDR := $(shell cat deployment/PccsDependencyConfig))
	$(eval X509_CRL_ADDR := $(shell cat deployment/X509CRLHelper))
	$(eval PCS_ADDR := $(shell cat deployment/AutomataPcsDao))
	$(eval PCK_ADDR := $(shell cat deployment/AutomataPckDao))
	$(eval TCB_EVAL_DAO_ADDR := $(shell cat deployment/AutomataTcbEvalDao))
	$(eval ENCLAVE_ID_ADDR := $(shell cat deployment/AutomataEnclaveIdentityDao))
	$(eval FMSPC_TCB_ADDR := $(shell cat deployment/AutomataFmspcTcbDaoVersioned))
	rex send $(STORAGE_ADDR) "grantDao(address)" $(PCS_ADDR) -k $(PRIVATE_KEY)
	rex send $(STORAGE_ADDR) "grantDao(address)" $(PCK_ADDR) -k $(PRIVATE_KEY)
	rex send $(STORAGE_ADDR) "grantDao(address)" $(TCB_EVAL_DAO_ADDR) -k $(PRIVATE_KEY)
	rex send $(STORAGE_ADDR) "grantDao(address)" $(ENCLAVE_ID_ADDR) -k $(PRIVATE_KEY)
	rex send $(STORAGE_ADDR) "grantDao(address)" $(FMSPC_TCB_ADDR) -k $(PRIVATE_KEY)
	rex send $(DEPCONFIG_ADDR) "initialize(address,address)" $(PCS_ADDR) $(X509_CRL_ADDR) -k $(PRIVATE_KEY)

deploy: deploy-and-configure

clean:
	rm -rf out lib deployment/PCKHelper deployment/X509CRLHelper \
		deployment/EnclaveIdentityHelper deployment/FmspcTcbHelper deployment/TcbEvalHelper \
		deployment/AutomataDaoStorage deployment/PccsDependencyConfig \
		deployment/AutomataPcsDao deployment/AutomataPckDao deployment/AutomataTcbEvalDao \
		deployment/AutomataEnclaveIdentityDao deployment/AutomataFmspcTcbDao \
		deployment/AutomataFmspcTcbDaoVersioned

.PHONY: deploy deploy-helpers deploy-storage deploy-pcs deploy-pck deploy-tcb-eval-dao \
	deploy-id-dao deploy-fmspc-tcb-dao deploy-and-configure clean
