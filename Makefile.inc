#TOOLS
BIGLOO = bigloo
BGLAFILE = bglafile
BGLJFILE = bgljfile
BGLTAGS = bgltags
LD = ld
AR = ar
JAR = jar
RANLIB = ranlib
INSTALL = install
LINK = ln
MAKEINFO = makeinfo

BIGLOO_VERSION := $(shell $(BIGLOO) -eval "(print *bigloo-version*) (exit 0)" -q)
BIGLOOLIBDIR := $(shell $(BIGLOO) -eval "(print *default-lib-dir*) (exit 0)" -q)


#install related variables
DESTDIR = /usr
INSTLIBDIR = $(DESTDIR)/lib
INSTBIGLOOLIBDIR = $(INSTLIBDIR)/bigloo/$(BIGLOO_VERSION)


#Bigloo Flags
BHEAPFLAGS = -I src/Llib -unsafe -q -mkaddheap -mkaddlib \
	     -heap-library $(LIBNAME)

BCOMMONFLAGS = -rm  -fsharing -q \
               -copt '$(CCOMMONFLAGS)' -I src/Llib

BSAFEFLAGS = $(BCOMMONFLAGS) -g3 -cg   

BPROFILEFLAGS = $(BCOMMONFLAGS) -p -O6

BUNSAFEFLAGS = $(BCOMMONFLAGS) -O6 -unsafe

#C Flags
CCOMMONFLAGS = $(CFLAGS) -fPIC

# directory variables
OBJDIR = objs
DISTDIR = dist
SCLASSDIR = classes_s/bigloo/concurrent
UCLASSDIR = classes_u/bigloo/concurrent
ESCLASSDIR = classes_es/bigloo/concurrent
EUCLASSDIR = classes_eu/bigloo/concurrent


# sources
BIGLOOSRCS = $(wildcard src/Llib/*.scm)
TESTSRCS = $(wildcard recette/*.scm)
HEAPSRC = src/Misc/make_lib.scm
DOCSRCS = $(wildcard manual/*.texi)
MACROSRCS = $(wildcard src/Llib/*.sch)

# object files
_TESTSRCSWOUTDIR = $(foreach src, $(TESTSRCS), $(notdir $(src)))
_SRCSWOUTDIR = $(foreach src, $(BIGLOOSRCS), $(notdir $(src)))
_BASEOBJSWOUTDIR = $(_SRCSWOUTDIR:%.scm=%)

SAFEOBJECTS = $(_BASEOBJSWOUTDIR:%=$(OBJDIR)/%_s.o)

PROFILEOBJECTS = $(_BASEOBJSWOUTDIR:%=$(OBJDIR)/%_p.o)

UNSAFEOBJECTS = $(_BASEOBJSWOUTDIR:%=$(OBJDIR)/%_u.o)

SAFECLASSES = $(_BASEOBJSWOUTDIR:%=$(SCLASSDIR)/%.class)

UNSAFECLASSES = $(_BASEOBJSWOUTDIR:%=$(UCLASSDIR)/%.class)


_ESRCSWOUTDIR = $(foreach src, $(HEAPSRC), $(notdir $(src)))
_EBASEOBJSWOUTDIR = $(_ESRCSWOUTDIR:%.scm=%)

ESAFEOBJECTS = $(_EBASEOBJSWOUTDIR:%=$(OBJDIR)/%_s.o)

EUNSAFEOBJECTS = $(_EBASEOBJSWOUTDIR:%=$(OBJDIR)/%_u.o)

ESAFECLASSES = $(_EBASEOBJSWOUTDIR:%=$(ESCLASSDIR)/%.class)

EUNSAFECLASSES = $(_EBASEOBJSWOUTDIR:%=$(EUCLASSDIR)/%.class)

TESTOBJECTS = $(TESTSRCS:%.scm=%.o)

TESTCLASSES = $(TESTSRCS:%.scm=%.class)

.SUFFIXES:

$(OBJDIR)/%_s.o:src/Llib/%.scm
	$(BIGLOO)  -c -mkaddlib $(BSAFEFLAGS) -o $@ $^

$(OBJDIR)/%_p.o:src/Llib/%.scm
	$(BIGLOO)  -c -mkaddlib $(BPROFILEFLAGS) -o $@ $^

$(OBJDIR)/%_u.o:src/Llib/%.scm
	$(BIGLOO)  -c -mkaddlib $(BUNSAFEFLAGS) -o $@ $^

$(SCLASSDIR)/%.class:src/Llib/%.scm
	$(BIGLOO) -jvm  -c -mkaddlib $(BSAFEFLAGS) -o $@ $^

$(UCLASSDIR)/%.class:src/Llib/%.scm
	$(BIGLOO) -jvm  -c -mkaddlib $(BUNSAFEFLAGS) -o $@ $^

recette/%.o:recette/%.scm heap
	$(BIGLOO)  -c $(BSAFEFLAGS) -L $(DISTDIR) -o $@ $<

recette/%.class:recette/%.scm heap
	$(BIGLOO) -jfile .recettejfile -jvm  -c $(BSAFEFLAGS) -L $(DISTDIR) -o $@ $<


#targets

c: .afile .etags lib 

jvm: .jfile .afile .etags libj

all: c jvm

test: c recette/test$(LIBNAME) 
	./recette/test$(LIBNAME)

jtest: jvm .recettejfile recette/jtest$(LIBNAME) 
	./recette/jtest$(LIBNAME)

manual: manual-html manual-pdf

manual-html : $(DOCSRCS)
	(cd manual; \
	makeinfo --html $(LIBNAME).texi)

manual-pdf : $(DOCSRCS)
	(cd manual; \
	makeinfo --pdf $(LIBNAME).texi)

.afile: $(BIGLOOSRCS)  $(TESTSRCS)
	$(BGLAFILE) -o $@  $^

.jfile: $(BIGLOOSRCS) $(HEAPSRC)
	$(BGLJFILE) -pbase bigloo.concurrent -o $@  -I recette -I src/Misc -I src/Llib $(_SRCSWOUTDIR) $(_ESRCSWOUTDIR)

.recettejfile: $(TESTSRCS)
	$(BGLJFILE) -pbase recette -o $@  -I recette  $(_TESTSRCSWOUTDIR)

.etags: $(BIGLOOSRCS) $(TESTSRCS) $(MACROSRCS)
	$(BGLTAGS) -o $@ $^

heap: $(DISTDIR)/$(LIBNAME).heap

jheap: $(DISTDIR)/$(LIBNAME).jheap 

$(DISTDIR)/$(LIBNAME).heap: $(DISTDIR) $(HEAPSRC)
	$(BIGLOO) $(BHEAPFLAGS) $(HEAPSRC)  -addheap $@

$(DISTDIR)/$(LIBNAME).jheap: $(DISTDIR) $(HEAPSRC)
	$(BIGLOO) -jvm  $(BHEAPFLAGS) $(HEAPSRC)  -addheap $@

$(OBJDIR)/make_lib_s.o:src/Misc/make_lib.scm
	$(BIGLOO) -c  -mkaddlib $(BSAFEFLAGS) -o $@ $^

$(ESCLASSDIR)/make_lib.class:src/Misc/make_lib.scm
	$(BIGLOO) -jvm  -c -mkaddlib $(BSAFEFLAGS) -o $@ $^


$(OBJDIR)/make_lib_u.o:src/Misc/make_lib.scm
	$(BIGLOO) -c -mkaddlib $(BUNSAFEFLAGS) -o $@ $^

$(EUCLASSDIR)/make_lib.class:src/Misc/make_lib.scm
	$(BIGLOO) -jvm -c -mkaddlib $(BUNSAFEFLAGS) -o $@ $^

lib: init heap $(DISTDIR)/lib$(LIBNAME)_s-$(VERSION).so  \
	       $(DISTDIR)/lib$(LIBNAME)_s-$(VERSION).a   \
               $(DISTDIR)/lib$(LIBNAME)_p-$(VERSION).so  \
	       $(DISTDIR)/lib$(LIBNAME)_p-$(VERSION).a   \
               $(DISTDIR)/lib$(LIBNAME)_es-$(VERSION).so \
	       $(DISTDIR)/lib$(LIBNAME)_u-$(VERSION).so  \
	       $(DISTDIR)/lib$(LIBNAME)_u-$(VERSION).a   \
	       $(DISTDIR)/lib$(LIBNAME)_eu-$(VERSION).so

libj: init jheap heap jar_s jar_u jar_es jar_eu

init: $(DISTDIR)/$(LIBNAME).init

$(DISTDIR)/$(LIBNAME).init : $(DISTDIR)  src/Misc/$(LIBNAME).init.in $(MACROSRCS)
	cat $(MACROSRCS) src/Misc/$(LIBNAME).init.in > $@

jar_s: $(SCLASSDIR)  $(DISTDIR) $(SAFECLASSES)
	$(JAR) -cf $(DISTDIR)/$(LIBNAME)_s-$(VERSION).zip -C $(SCLASSDIR)/../../ .

jar_u: $(UCLASSDIR) $(EUCLASSDIR) $(DISTDIR) $(UNSAFECLASSES)
	$(JAR) -cf $(DISTDIR)/$(LIBNAME)_u-$(VERSION).zip -C $(UCLASSDIR)/../../ .   

jar_es : $(ESCLASSDIR) $(DISTDIR) $(ESAFECLASSES)
	$(JAR) -cf $(DISTDIR)/$(LIBNAME)_es-$(VERSION).zip -C $(ESCLASSDIR)/../../ . 


jar_eu : $(UCLASSDIR) $(DISTDIR) $(EUNSAFECLASSES)
	$(JAR) -cf $(DISTDIR)/$(LIBNAME)_eu-$(VERSION).zip -C $(UCLASSDIR)/../../ .


$(DISTDIR)/lib$(LIBNAME)_s-$(VERSION).so: $(OBJDIR) $(DISTDIR) $(SAFEOBJECTS)
	$(LD) -G -o $(DISTDIR)/lib$(LIBNAME)_s-$(VERSION).so $(SAFEOBJECTS) -lc -lm

$(DISTDIR)/lib$(LIBNAME)_s-$(VERSION).a : $(OBJDIR) $(DISTDIR) $(SAFEOBJECTS)
	$(AR) qcv $(DISTDIR)/lib$(LIBNAME)_s-$(VERSION).a $(SAFEOBJECTS);\
	$(RANLIB) $(DISTDIR)/lib$(LIBNAME)_s-$(VERSION).a

$(DISTDIR)/lib$(LIBNAME)_p-$(VERSION).so: $(OBJDIR) $(DISTDIR) $(PROFILEOBJECTS)
	$(LD) -G -o $(DISTDIR)/lib$(LIBNAME)_p-$(VERSION).so $(PROFILEOBJECTS) -lc -lm

$(DISTDIR)/lib$(LIBNAME)_p-$(VERSION).a : $(OBJDIR) $(DISTDIR) $(PROFILEOBJECTS)
	$(AR) qcv $(DISTDIR)/lib$(LIBNAME)_p-$(VERSION).a $(PROFILEOBJECTS);\
	$(RANLIB) $(DISTDIR)/lib$(LIBNAME)_p-$(VERSION).a


$(DISTDIR)/lib$(LIBNAME)_es-$(VERSION).so : $(OBJDIR) $(DISTDIR) $(ESAFEOBJECTS)
	$(LD) -G -o $(DISTDIR)/lib$(LIBNAME)_es-$(VERSION).so $(ESAFEOBJECTS) -lc -lm

$(DISTDIR)/lib$(LIBNAME)_u-$(VERSION).so : $(OBJDIR) $(DISTDIR) $(UNSAFEOBJECTS)
	$(LD) -G -o $(DISTDIR)/lib$(LIBNAME)_u-$(VERSION).so $(UNSAFEOBJECTS) -lc -lm

$(DISTDIR)/lib$(LIBNAME)_u-$(VERSION).a : $(OBJDIR) $(DISTDIR) $(UNSAFEOBJECTS)
	$(AR) qcv $(DISTDIR)/lib$(LIBNAME)_u-$(VERSION).a $(SAFEOBJECTS);\
	$(RANLIB) $(DISTDIR)/lib$(LIBNAME)_u-$(VERSION).a

$(DISTDIR)/lib$(LIBNAME)_eu-$(VERSION).so : $(OBJDIR) $(DISTDIR) $(EUNSAFEOBJECTS)
	$(LD) -G -o $(DISTDIR)/lib$(LIBNAME)_eu-$(VERSION).so $(EUNSAFEOBJECTS) -lc -lm


recette/test$(LIBNAME) : $(TESTOBJECTS) lib 
	$(BIGLOO) -static-all-bigloo $(BSAFEFLAGS) -L $(DISTDIR) -o $@ $(TESTOBJECTS)

recette/jtest$(LIBNAME) : $(TESTCLASSES) libj 
	$(BIGLOO) -jfile .recettejfile -jvm -static-all-bigloo $(BSAFEFLAGS) -L $(DISTDIR) -o $@ $(TESTCLASSES) 



$(OBJDIR):
	mkdir $@

$(DISTDIR):
	mkdir $@

$(SCLASSDIR):
	mkdir -p $@

$(UCLASSDIR):
	mkdir -p $@

$(ESCLASSDIR):
	mkdir -p $@

$(EUCLASSDIR):
	mkdir -p $@


check-syntax: .afile
	$(BIGLOO) $(BCOMMONFLAGS) -afile .afile -syntax-check ${CHK_SOURCES}


install: all
	for file in $(DISTDIR)/*; do \
	  $(INSTALL) $$file $(INSTBIGLOOLIBDIR)/`basename $$file`; \
	done; \

clean:
	rm -f $(TESTOBJECTS);\
	rm -f $(TESTCLASSES);\
	rm -f -r $(OBJDIR);\
	rm -f -r $(DISTDIR);\
	rm -f -r $(SCLASSDIR);\
	rm -f -r $(UCLASSDIR);\
	rm -f -r $(ESCLASSDIR);\
	rm -f -r $(EUCLASSDIR);\
	rm -f $(LIBNAME).heap;\
	rm -f $(LIBNAME).jheap;\
	rm -f $(LIBNAME).init;\
	rm -f .afile;\
	rm -f .jfile;\
	rm -f .recettejfile;\
	rm -f recette/jtest$(LIBNAME);\
	rm -f recette/test$(LIBNAME)



