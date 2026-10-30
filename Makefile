IMAGE ?= cilo-raft-proof

.PHONY: docker local clean
# build the image and run all three checks (writes logs to ./results)
docker:
	docker build -t $(IMAGE) .
	docker run --rm -v "$(CURDIR)/results:/proof/results" $(IMAGE)

# run with a local Java 11+ and tla2tools.jar (TLA2TOOLS=/path/to/tla2tools.jar)
local:
	bash run.sh

clean:
	rm -rf results states *_TTrace_*
