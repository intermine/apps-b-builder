test:
	./node_modules/.bin/mocha --compilers coffee:coffee-script --reporter spec --ui exports --bail --slow 300

.PHONY: test