$(eval CHAIN_ID := $(shell rex chain-id))
$(eval OWNER := $(shell rex address))

SOLC_FLAGS := --overwrite --optimize --via-ir

P256_ADDR := 0xc2b78104907F722DABAc4C69f826a522B2754De4

# Pinned dependency revisions. lib/ is gitignored, so these are the only record
# of what a deployment was built from. Both libraries reach the bytecode.
# Comments stay off the value lines: Make keeps whitespace before an inline `#`.
# openzeppelin v5.7.0; byte-identical to the master tip it replaced.
OPENZEPPELIN_REV = cab19933c33c2ad1d4c7a84864a3601dddfd16f3
# solady main tip, 23 commits past v0.1.26. Bumping to v0.1.26 changes only the
# metadata CBOR hash, not executable code, but is still a deliberate change.
SOLADY_REV = c251232428b668a073293eb04c6c288b19ad5728

# Clone if absent, then re-assert and verify the pin on every run, so a stale or
# half-checked-out lib/ is corrected rather than silently reused. After editing a
# revision above, `make clean` to rebuild out/.
define pin
	@test -d $(1)/.git || git clone -q $(2) $(1)
	@git -C $(1) cat-file -e "$(3)^{commit}" 2>/dev/null || git -C $(1) fetch -q --tags origin
	@git -c advice.detachedHead=false -C $(1) checkout -q --detach $(3)
	@test "$$(git -C $(1) rev-parse HEAD)" = "$(3)" || { echo "$(1): not at $(3)"; exit 1; }
endef

.PHONY: deps
deps:
	mkdir -p deployment
	$(call pin,lib/openzeppelin,https://github.com/OpenZeppelin/openzeppelin-contracts,$(OPENZEPPELIN_REV))
	$(call pin,lib/solady,https://github.com/vectorized/solady,$(SOLADY_REV))

out/AutomataDaoStorage.bin: | deps
	solc src/automata_pccs/shared/AutomataDaoStorage.sol --bin -o out/ $(SOLC_FLAGS)

out/AutomataFmspcTcbDao.bin: | deps
	solc src/automata_pccs/AutomataFmspcTcbDao.sol --bin -o out/ $(SOLC_FLAGS)

out/AutomataEnclaveIdentityDao.bin: | deps
	solc src/automata_pccs/AutomataEnclaveIdentityDao.sol --bin -o out/ $(SOLC_FLAGS)

out/AutomataPcsDao.bin: | deps
	solc src/automata_pccs/AutomataPcsDao.sol --bin -o out/ $(SOLC_FLAGS)

out/AutomataPckDao.bin: | deps
	solc src/automata_pccs/AutomataPckDao.sol --bin -o out/ $(SOLC_FLAGS)

out/EnclaveIdentityHelper.bin: | deps
	solc src/helpers/EnclaveIdentityHelper.sol --bin -o out/ $(SOLC_FLAGS)

out/FmspcTcbHelper.bin: | deps
	solc src/helpers/FmspcTcbHelper.sol --bin -o out/ $(SOLC_FLAGS)

out/PCKHelper.bin: | deps
	solc src/helpers/PCKHelper.sol --bin -o out/ $(SOLC_FLAGS)

out/X509CRLHelper.bin: | deps
	solc src/helpers/X509CRLHelper.sol --bin -o out/ $(SOLC_FLAGS)

deploy-helpers: out/EnclaveIdentityHelper.bin out/FmspcTcbHelper.bin out/PCKHelper.bin out/X509CRLHelper.bin
	rex deploy --print-address $(shell cat out/EnclaveIdentityHelper.bin) 0 $(PRIVATE_KEY) > deployment/EnclaveIdentityHelper
	rex deploy --print-address $(shell cat out/FmspcTcbHelper.bin) 0 $(PRIVATE_KEY) > deployment/FmspcTcbHelper
	rex deploy --print-address $(shell cat out/PCKHelper.bin) 0 $(PRIVATE_KEY) > deployment/PCKHelper
	rex deploy --print-address $(shell cat out/X509CRLHelper.bin) 0 $(PRIVATE_KEY) > deployment/X509CRLHelper

deploy-storage: out/AutomataDaoStorage.bin deploy-helpers
	rex deploy --print-address $(shell cat out/AutomataDaoStorage.bin) 0 $(PRIVATE_KEY) -- \
		"constructor(address)" $(OWNER) > deployment/AutomataDaoStorage

deploy-pcs: out/AutomataPcsDao.bin deploy-storage deploy-helpers
	$(eval STORAGE_ADDR := $(shell cat deployment/AutomataDaoStorage))
	$(eval X509_ADDR := $(shell cat deployment/PCKHelper))
	$(eval X509_CRL_ADDR := $(shell cat deployment/X509CRLHelper))
	rex deploy --print-address $(shell cat out/AutomataPcsDao.bin) 0 $(PRIVATE_KEY) -- \
		"constructor(address,address,address,address)" $(STORAGE_ADDR) $(P256_ADDR) $(X509_ADDR) $(X509_CRL_ADDR) \
		> deployment/AutomataPcsDao

deploy-pck: out/AutomataPckDao.bin deploy-storage deploy-helpers deploy-pcs
	$(eval STORAGE_ADDR := $(shell cat deployment/AutomataDaoStorage))
	$(eval X509_ADDR := $(shell cat deployment/PCKHelper))
	$(eval X509_CRL_ADDR := $(shell cat deployment/X509CRLHelper))
	$(eval PCS_ADDR := $(shell cat deployment/AutomataPcsDao))
	rex deploy --print-address $(shell cat out/AutomataPckDao.bin) 0 $(PRIVATE_KEY) -- \
		"constructor(address,address,address,address,address)" \
		$(STORAGE_ADDR) $(P256_ADDR) $(PCS_ADDR) $(X509_ADDR) $(X509_CRL_ADDR) \
		> deployment/AutomataPckDao

deploy-id-dao: out/AutomataEnclaveIdentityDao.bin deploy-storage deploy-pcs deploy-helpers
	$(eval STORAGE_ADDR := $(shell cat deployment/AutomataDaoStorage))
	$(eval X509_ADDR := $(shell cat deployment/PCKHelper))
	$(eval X509_CRL_ADDR := $(shell cat deployment/X509CRLHelper))
	$(eval PCS_ADDR := $(shell cat deployment/AutomataPcsDao))
	$(eval ENCLAVE_HELPER_ADDR := $(shell cat deployment/EnclaveIdentityHelper))
	rex deploy --print-address $(shell cat out/AutomataEnclaveIdentityDao.bin) 0 $(PRIVATE_KEY) -- \
		"constructor(address,address,address,address,address,address)" \
		$(STORAGE_ADDR) $(P256_ADDR) $(PCS_ADDR) $(ENCLAVE_HELPER_ADDR) $(X509_ADDR) $(X509_CRL_ADDR) \
		> deployment/AutomataEnclaveIdentityDao

deploy-fmspc-tcb-dao: out/AutomataFmspcTcbDao.bin deploy-storage deploy-pcs deploy-helpers
	$(eval STORAGE_ADDR := $(shell cat deployment/AutomataDaoStorage))
	$(eval X509_ADDR := $(shell cat deployment/PCKHelper))
	$(eval X509_CRL_ADDR := $(shell cat deployment/X509CRLHelper))
	$(eval PCS_ADDR := $(shell cat deployment/AutomataPcsDao))
	$(eval FMSPC_TCB_HELPER_ADDR := $(shell cat deployment/FmspcTcbHelper))
	rex deploy --print-address $(shell cat out/AutomataFmspcTcbDao.bin) 0 $(PRIVATE_KEY) -- \
		"constructor(address,address,address,address,address,address)" \
		$(STORAGE_ADDR) $(P256_ADDR) $(PCS_ADDR) $(FMSPC_TCB_HELPER_ADDR) $(X509_ADDR) $(X509_CRL_ADDR) \
		> deployment/AutomataFmspcTcbDao

deploy-and-configure: deploy-storage deploy-pcs deploy-pck deploy-id-dao deploy-fmspc-tcb-dao
	$(eval STORAGE_ADDR := $(shell cat deployment/AutomataDaoStorage))
	$(eval PCS_ADDR := $(shell cat deployment/AutomataPcsDao))
	$(eval PCK_ADDR := $(shell cat deployment/AutomataPckDao))
	$(eval ENCLAVE_ID_ADDR := $(shell cat deployment/AutomataEnclaveIdentityDao))
	$(eval FMSPC_TCB_ADDR := $(shell cat deployment/AutomataFmspcTcbDao))
	rex send $(STORAGE_ADDR) "grantDao(address)" $(PCS_ADDR) -k $(PRIVATE_KEY)
	rex send $(STORAGE_ADDR) "grantDao(address)" $(PCK_ADDR) -k $(PRIVATE_KEY)
	rex send $(STORAGE_ADDR) "grantDao(address)" $(ENCLAVE_ID_ADDR) -k $(PRIVATE_KEY)
	rex send $(STORAGE_ADDR) "grantDao(address)" $(FMSPC_TCB_ADDR) -k $(PRIVATE_KEY)

deploy: deploy-and-configure

.PHONY: deploy-*
