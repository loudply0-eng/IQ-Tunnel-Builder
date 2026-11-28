# gomobile's native JNI runtime resolves these classes and helper methods by
# exact names through FindClass/GetStaticMethodID. R8 cannot infer those lookups.
# Preserve the complete Go bridge runtime, including Seq.getRef, Seq.incRef,
# Seq.incRefnum, Seq.decRef, and Seq.throwException.
-keep class go.** { *; }

# Preserve generated libXray binding classes and callback interfaces that cross
# the JNI boundary. Their Java names/signatures must remain stable in release APKs.
-keep class libXray.** { *; }
