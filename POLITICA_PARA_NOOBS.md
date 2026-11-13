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


## Actualización R125: primer pulso, edades y mesa por turnos

- Al abrir una sala, el anfitrión indica **una edad por participante**; el servidor conserva únicamente el tramo de lenguaje (`teen_early`, `teen`, `mixed`, `adult`), no las edades exactas.
- **Primero seis preguntas rápidas de seis Hot Points distintos**. Todos votan A/B/Depende en cada pregunta y todavía no se abre el debate. La mesa puede comparar los resultados.
- El anfitrión inicia la **fase de debate profundo**. Escoge Hot Point, DILEMA propone una pregunta nueva y todos vuelven a votar. El turno se asigna a una persona.
- **Solo la persona que tiene el turno** puede pasar la palabra, pedir Contradíceme/Punto ciego/Otra mirada, abrir otra pregunta o proponer finalizar. Estas condiciones se verifican también mediante funciones SQL autenticadas.
- La persona en turno puede proponer finalizar; **cada participante vota sí/no**. Con mayoría absoluta de respuestas afirmativas y tras votar todos, se cierra; los empates o rechazos mantienen el debate.
- **DILEMA dicta sentencia** al cierre: resumen descriptivo de los temas, discrepancias y dudas del grupo a partir de resultados agregados; no recomienda partidos ni deduce tendencias de voto. Se conservan fuentes oficiales en la revelación.
- Hay **96 situaciones nuevas redactadas para principiantes**, además del banco editorial anterior, y generación dinámica de preguntas que evita repeticiones en la misma sala.
- Pantalla de debate `100dvh` con scroll interno de las preguntas, cabecera fija de la propia interfaz y herramientas/entrada debajo, sin desplazamiento de toda la página.
- CSS mantiene la codificación de colores de los estados y botón **OTRA PREGUNTA** en naranja `#FF9F43`.
- Las pruebas automatizadas con rollback han verificado pulso de seis preguntas, paso a debate, turno individual, prohibición de intervenir fuera de turno, consenso de cierre y escenario de empate.
- **Pendiente:** prueba manual en Safari con varios teléfonos, verificación visual de teclado/área segura y revisión de privacidad antes de ampliar distribución.

