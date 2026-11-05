"""Ajusta a pasta android/ gerada pelo `flutter create`:
copia o código nativo, adiciona permissões, serviço, atividade e ML Kit."""
import pathlib
import re
import shutil
import sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
app = root / "android" / "app"

# 1. Código Kotlin no pacote do MainActivity gerado
main_act = next(app.glob("src/main/kotlin/**/MainActivity.kt"))
pkg_dir = main_act.parent
for src in (root / "android_src" / "kotlin").glob("*.kt"):
    shutil.copy(src, pkg_dir / src.name)
print("kotlin ->", pkg_dir)

# 2. Manifest
m = app / "src" / "main" / "AndroidManifest.xml"
xml = m.read_text()
perms = [
    "android.permission.INTERNET",
    "android.permission.SYSTEM_ALERT_WINDOW",
    "android.permission.FOREGROUND_SERVICE",
    "android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION",
    "android.permission.FOREGROUND_SERVICE_SPECIAL_USE",
    "android.permission.POST_NOTIFICATIONS",
]
perm_xml = "".join(
    f'    <uses-permission android:name="{p}"/>\n' for p in perms if p not in xml
)
xml = xml.replace("<application", perm_xml + "    <application", 1)
components = """
        <service
            android:name=".OverlayService"
            android:exported="false"
            android:foregroundServiceType="specialUse|mediaProjection">
            <property
                android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE"
                android:value="Bolha flutuante com assistente de draft sobre o jogo"/>
        </service>
        <activity
            android:name=".CaptureActivity"
            android:exported="false"
            android:excludeFromRecents="true"
            android:noHistory="true"
            android:theme="@android:style/Theme.Translucent.NoTitleBar"/>
"""
xml = xml.replace("</application>", components + "    </application>", 1)
xml = re.sub(r'android:label="[^"]*"', 'android:label="Rift Helper"', xml, count=1)
m.write_text(xml)
print("manifest ok")

# 3. Dependência do ML Kit (reconhecimento de texto, roda no aparelho)
kts = app / "build.gradle.kts"
groovy = app / "build.gradle"
if kts.exists():
    kts.write_text(kts.read_text() + '\ndependencies {\n    implementation("com.google.mlkit:text-recognition:16.0.1")\n}\n')
    print("gradle kts ok")
else:
    groovy.write_text(groovy.read_text() + "\ndependencies {\n    implementation 'com.google.mlkit:text-recognition:16.0.1'\n}\n")
    print("gradle groovy ok")
