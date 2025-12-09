.PHONY: help run restart stop clean logs stats

# Valid namespaces
VALID_NS := s1 s2 s3 s4 s5 qa auto

help:
	@echo "Orange Health Local Development"
	@echo ""
	@echo "Commands:"
	@echo "  make run [namespace] [services...]    - Start services (default: s1)"
	@echo "  make run refresh [namespace] [...]    - Start with fresh pull from git"
	@echo "  make restart [namespace]              - Restart all (force redis reconnect)"
	@echo "  make restart refresh [namespace]      - Restart with fresh pull"
	@echo "  make stop                             - Stop all services"
	@echo "  make clean                            - Clean everything"
	@echo "  make logs [service]                   - View logs"
	@echo "  make stats [service]                  - View resource usage"
	@echo ""
	@echo "Valid namespaces: s1, s2, s3, s4, s5, qa, auto"
	@echo ""
	@echo "Examples:"
	@echo "  make run                              - Start all with s1 (default)"
	@echo "  make run s2                           - Start all with s2 namespace"
	@echo "  make run s1 health-api                - Start only health-api"
	@echo "  make run refresh s2                   - Start all, pull latest code"
	@echo "  make run refresh s1 health-api        - Pull and start health-api"
	@echo "  make restart                          - Restart all"
	@echo "  make restart refresh                  - Restart with fresh pull"

run:
	@./run.sh --run $(filter-out $@,$(MAKECMDGOALS))

restart:
	@./run.sh --restart $(filter-out $@,$(MAKECMDGOALS))

stop:
	@./run.sh --stop

clean:
	@./run.sh --clean

logs:
	@./run.sh --logs $(filter-out $@,$(MAKECMDGOALS))

stats:
	@./run.sh --stats $(filter-out $@,$(MAKECMDGOALS))

# Allow any target (namespaces, service names, flags)
s1 s2 s3 s4 s5 qa auto refresh:
	@:

health-api scheduler-api oms-api oms:
	@:

%:
	@:
