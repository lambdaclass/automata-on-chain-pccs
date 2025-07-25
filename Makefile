$(eval CHAIN_ID := $(shell rex chain-id))
$(eval OWNER := $(shell rex address))

SOLC_FLAGS := --overwrite --optimize --via-ir

P256_ADDR := 0xc2b78104907F722DABAc4C69f826a522B2754De4

lib/openzeppelin:
	git clone https://github.com/OpenZeppelin/openzeppelin-contracts lib/openzeppelin

lib/solady:
	git clone https://github.com/vectorized/solady lib/solady

deps: lib/openzeppelin lib/solady
	mkdir -p deployment

out/AutomataDaoStorage.bin: deps
	solc src/automata_pccs/shared/AutomataDaoStorage.sol --bin -o out/ $(SOLC_FLAGS)

out/AutomataFmspcTcbDao.bin: deps
	solc src/automata_pccs/AutomataFmspcTcbDao.sol --bin -o out/ $(SOLC_FLAGS)

out/AutomataEnclaveIdentityDao.bin: deps
	solc src/automata_pccs/AutomataEnclaveIdentityDao.sol --bin -o out/ $(SOLC_FLAGS)

out/AutomataPcsDao.bin: deps
	solc src/automata_pccs/AutomataPcsDao.sol --bin -o out/ $(SOLC_FLAGS)

out/AutomataPckDao.bin: deps
	solc src/automata_pccs/AutomataPckDao.sol --bin -o out/ $(SOLC_FLAGS)

out/EnclaveIdentityHelper.bin: deps
	solc src/helpers/EnclaveIdentityHelper.sol --bin -o out/ $(SOLC_FLAGS)

out/FmspcTcbHelper.bin: deps
	solc src/helpers/FmspcTcbHelper.sol --bin -o out/ $(SOLC_FLAGS)

out/PCKHelper.bin: deps
	solc src/helpers/PCKHelper.sol --bin -o out/ $(SOLC_FLAGS)

out/X509CRLHelper.bin: deps
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
	rex send $(STORAGE_ADDR) "grantDao(address)" $(PCS_ADDR) --value 0 -k $(PRIVATE_KEY)
	rex send $(STORAGE_ADDR) "grantDao(address)" $(PCK_ADDR) --value 0 -k $(PRIVATE_KEY)
	rex send $(STORAGE_ADDR) "grantDao(address)" $(ENCLAVE_ID_ADDR) --value 0 -k $(PRIVATE_KEY)
	rex send $(STORAGE_ADDR) "grantDao(address)" $(FMSPC_TCB_ADDR) --value 0 -k $(PRIVATE_KEY)

deploy: deploy-and-configure

.PHONY: deploy-*
