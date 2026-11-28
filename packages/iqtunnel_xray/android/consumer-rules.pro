# gomobile's native JNI runtime resolves helper methods by exact names through
# GetStaticMethodID/FindClass. R8 cannot infer those native lookups, so preserve
# the complete runtime classes and every member (including private static methods).
-keep class go.** { *; }

# Preserve generated libXray binding classes and callback interfaces crossing
# the JNI boundary. Their Java names and signatures must remain stable.
-keep class libXray.** { *; }
