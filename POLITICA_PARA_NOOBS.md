# DILEMA · POLÍTICA PARA NOOBS

Módulo de debate cívico y comparativa documental del 29N 2026, desarrollado de forma **aislada** del debate convencional y de JUEGO.

## Experiencia

1. Anfitrión crea una sala de **1 a 20 participantes**, comparte el enlace y elige un **Hot Point**.
2. El moderador `politics-moderator` solicita a la IA una pregunta nueva de alternativas A/B y una repregunta de tensión. Si falla la IA, selecciona una de las preguntas del banco editorial sin repetir en la sala.
3. Cada ronda requiere **nueva votación A/B/Depende**. La sala no publica resultados hasta que han votado todas las personas activas.
4. Se abre el debate con turnos, y la IA puede plantear objeciones, puntos ciegos y otras miradas. En el modo 1 persona admite hasta 5 turnos de argumento escrito + repregunta.
5. Se abre una ronda diferente con nueva votación o se termina el Hot Point para revelar siglas y **documentos electorales verificables**.
6. El mapa de ideas refleja únicamente los **porcentajes de respuestas A/B/Depende por ronda**; no puntúa ni recomienda candidatos, partidos ni voto.

## Datos y seguridad

- GitHub Pages aloja únicamente HTML/JS públicos; **sin claves secretas**.
- La IA se llama mediante la función autenticada de Supabase, con clave OpenAI en los secretos del servidor.
- Tablas separadas `private.politics_*`, RLS activo, permisos directos revocados. Los votos se consultan solo agregados por miembro, y cada persona puede consultar su propio voto.
- Creación/acceso requiere consentimiento explícito. No se pide DNI, correo, perfil político ni dirección.
- El anfitrión al salir cierra y elimina sala/votos. Salida de invitado elimina su participación y votos.
- Limpieza automática programada para no superar aproximadamente 72 horas. La página no guarda los argumentos escritos en la base de datos.
- Las peticiones de IA se limitan por sala/ronda, usuario y cupo diario global.
- Para una apertura pública destinada a menores o a un público amplio, pendiente de revisión legal y de privacidad.

## Fuentes

- Las tarjetas de propuestas (30 en esta versión) corresponden a documentos oficiales localizados de **PP, Vox, PNV y contrato electoral simplificado de SALF**, con enlaces a PDF y páginas.
- El resto de candidaturas principales (PSOE, Frente Amplio, Podemos, EH Bildu y PCTE) se indica expresamente como pendiente, sin atribuirles medidas no verificadas.
- Cada Hot Point proporciona contexto documental a la IA cuando existe. Una pregunta sobre política pública no es una promesa atribuida a una formación.
- Actualizar las fuentes requiere revisar primero el PDF oficial y registrar su página. No inventar propuestas ni inferirlas por ideología.

## Verificaciones

**Automáticas/estructura realizadas**
- Parseo JavaScript sin error.
- Todos los identificadores de UI utilizados por el JS existen en HTML.
- Pruebas transaccionales SQL con rollback: votación individual, 2 participantes, votos ocultos hasta cerrar ronda, pregunta diferente en segunda ronda, turnos, repregunta compartida, revelación de datos, consentimiento, límite de solicitudes de IA y eliminación de sala.
- Inspección de permisos: RPCs sin consentimiento y voto público anónimo no disponibles.

**Pruebas manuales antes de ampliar el acceso**
- Confirmar inicio de sesión anónimo en Safari iOS.
- Crear sala de 1 persona, votar, debatir por escrito y abrir una nueva ronda.
- Crear sala de 2 o más desde navegadores o dispositivos independientes; probar enlace/código, estado de votos, turnos y revelación.
- Comprobar que el proveedor IA responde realmente desde el entorno web y que la caída se resuelve con el banco editorial sin bloquear la sala.
- Verificar accesibilidad visual y UX con menores bajo supervisión.

**No se realizan tests de afinidad ideológica ni se ofrece recomendación de voto.**
