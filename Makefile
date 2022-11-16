ERL=erl
APPFILE=tircd.app

all: ebin/$(APPFILE)
	$(ERL) -make 

ebin/$(APPFILE): src/$(APPFILE)
	cp $< $@
