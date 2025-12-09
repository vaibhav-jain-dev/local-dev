.PHONY: help start stop clean logs stats

help:
	@echo "Orange Health Local Development"
	@echo ""
	@echo "Commands:"
	@echo "  make start [service] [tag=TAG]  - Start all or specific service"
	@echo "  make stop                       - Stop all services"
	@echo "  make clean                      - Clean everything"
	@echo "  make logs [service]             - View logs"
	@echo "  make stats [service]            - View resource usage"
	@echo ""
	@echo "Examples:"
	@echo "  make start                      - Start all enabled services"
	@echo "  make start health-api           - Start only health-api"
	@echo "  make start tag=s5               - Start with s5 environment"
	@echo "  make start health-api tag=s5    - Start health-api with s5 env"
	@echo "  make logs health-api            - View health-api logs"
	@echo "  make stats                      - View all resource usage"
	@echo ""
	@echo "Tag variations (all work the same):"
	@echo "  tag=s5  or  -tag s5  or  --tag s5"

start:
	@if [ -n "$(tag)" ]; then \
		./run.sh --tag $(tag) $(filter-out $@,$(MAKECMDGOALS)); \
	else \
		./run.sh $(filter-out $@,$(MAKECMDGOALS)); \
	fi

stop:
	@./run.sh --stop

clean:
	@./run.sh --clean

logs:
	@./run.sh --logs $(filter-out $@,$(MAKECMDGOALS))

stats:
	@./run.sh --stats $(filter-out $@,$(MAKECMDGOALS))

# Service name targets - allow hyphenated names
health-api scheduler-api oms:
	@:

%:
	@:
