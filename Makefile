.PHONY: help run restart stop clean logs stats

# Valid namespaces
VALID_NS := s1 s2 s3 s4 s5 qa auto

help:
	@echo "Orange Health Local Development"
	@echo ""
	@echo "Commands:"
	@echo "  make run [namespace] [services...]  - Start services (default: s1, all services)"
	@echo "  make restart [namespace]            - Restart all services (force reconnect redis)"
	@echo "  make stop                           - Stop all services"
	@echo "  make clean                          - Clean everything"
	@echo "  make logs [service]                 - View logs"
	@echo "  make stats [service]                - View resource usage"
	@echo ""
	@echo "Valid namespaces: s1, s2, s3, s4, s5, qa, auto"
	@echo ""
	@echo "Examples:"
	@echo "  make run                            - Start all services with s1 (default)"
	@echo "  make run s2                         - Start all services with s2 namespace"
	@echo "  make run s1 health-api              - Start only health-api with s1"
	@echo "  make run s2 health-api oms-api      - Start health-api and oms-api with s2"
	@echo "  make restart                        - Restart all (force redis reconnect)"
	@echo "  make restart s2                     - Restart with s2 namespace"
	@echo "  make logs health-api                - View health-api logs"

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

# Allow any target (namespaces, service names)
s1 s2 s3 s4 s5 qa auto:
	@:

health-api scheduler-api oms-api oms:
	@:

%:
	@:
