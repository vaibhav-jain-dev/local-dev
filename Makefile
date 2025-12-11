.PHONY: help run restart stop clean logs stats dashboard

# Valid namespaces
VALID_NS := s1 s2 s3 s4 s5 qa auto

help:
	@echo "Orange Health Local Development"
	@echo ""
	@echo "Commands:"
	@echo "  make run [namespace] [services...]    - Start services (default: s1)"
	@echo "  make run refresh [namespace] [...]    - Start with fresh pull from git"
	@echo "  make run --include-app [namespace]    - Start with Android emulators"
	@echo "  make restart [namespace]              - Restart all (force redis reconnect)"
	@echo "  make restart refresh [namespace]      - Restart with fresh pull"
	@echo "  make stop                             - Stop all services"
	@echo "  make clean                            - Clean everything"
	@echo "  make logs [service]                   - View logs"
	@echo "  make stats [service]                  - View resource usage"
	@echo ""
	@echo "Valid namespaces: s1, s2, s3, s4, s5, qa, auto"
	@echo ""
	@echo "Flags:"
	@echo "  refresh           - Pull latest code from git before starting"
	@echo "  --include-app     - Include Android emulator apps (patient-app, doctor-app)"
	@echo "  --live / -l       - Show auto-scrolling live build logs"
	@echo "  --dashboard / d   - Launch web dashboard at http://localhost:9999"
	@echo "  --local redis     - Use local Docker Redis instead of K8s port-forward"
	@echo ""
	@echo "Workers (auto-started with oms-api):"
	@echo "  oms-worker, oms-worker-scheduler, oms-consumer-worker"
	@echo ""
	@echo "Examples:"
	@echo "  make run                              - Start all with s1 (default)"
	@echo "  make run s2                           - Start all with s2 namespace"
	@echo "  make run s1 health-api                - Start only health-api"
	@echo "  make run s1 oms-api                   - Start oms-api with all workers"
	@echo "  make run refresh s2                   - Start all, pull latest code"
	@echo "  make run refresh s1 health-api        - Pull and start health-api"
	@echo "  make run --include-app s1             - Start all with Android emulators"
	@echo "  make run --live s1                    - Start with live scrolling logs"
	@echo "  make run d                            - Start with web dashboard UI"
	@echo "  make run --dashboard s1               - Start with web dashboard UI"
	@echo "  make run --local redis                - Start with local Docker Redis"
	@echo "  make dashboard                        - Open dashboard only (no restart)"
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

dashboard:
	@./run.sh --dashboard-only

# Allow any target (namespaces, service names, flags)
# Note: Use 'd' without dash as shorthand for dashboard (make interprets '-d' as its debug flag)
s1 s2 s3 s4 s5 qa auto refresh --include-app --live -l --dashboard d --ui --local redis:
	@:

health-api scheduler-api oms-api oms bifrost oms-web patient-app doctor-app:
	@:

%:
	@:
