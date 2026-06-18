import Foundation

/// Top-1000 word frequency bonus — common words score higher
final class WordFrequency {
    private var topWordsRU: Set<String> = []
    private var topWordsEN: Set<String> = []

    init() {
        // Top 200 most frequent Russian words
        topWordsRU = Set([
            "и","в","не","на","я","что","он","с","это","а","как","но","все","она","так",
            "его","только","мне","было","еще","бы","мы","вот","за","то","по","от","вы",
            "же","ты","да","ее","уже","к","ну","тут","мой","из","тебя","когда","нет",
            "них","нас","сейчас","для","если","может","есть","чтобы","себя","при","этом",
            "надо","тебе","тоже","потом","где","ни","время","очень","после","будет","они",
            "был","даже","ему","здесь","нет","раз","один","там","два","знаю","люди",
            "этот","ничего","лет","теперь","хотя","более","день","первый","мир","между",
            "какой","место","жизнь","через","должен","другой","каждый","стал","чем","дело",
            "большой","год","новый","свой","работа","конечно","дом","слово","вопрос","много",
            "город","ответ","наш","хорошо","деньги","число","иметь","дать","хотеть","нужно",
            "сказать","думать","знать","говорить","видеть","стоять","идти","делать","мочь",
            "быть","стать","начать","понять","работать","любить","жить","ходить","взять",
            "привет","спасибо","пожалуйста","здравствуйте","пока","сегодня","завтра","вчера",
            "утро","вечер","ночь","день","неделя","месяц","книга","школа","дорога","рука",
            "глаз","голова","ребенок","друг","женщина","мужчина","земля","вода","страна",
        ])

        // Top 200 most frequent English words
        topWordsEN = Set([
            "the","be","to","of","and","a","in","that","have","i","it","for","not","on",
            "with","he","as","you","do","at","this","but","his","by","from","they","we",
            "say","her","she","or","an","will","my","one","all","would","there","their",
            "what","so","up","out","if","about","who","get","which","go","me","when",
            "make","can","like","time","no","just","him","know","take","people","into",
            "year","your","good","some","could","them","see","other","than","then","now",
            "look","only","come","its","over","think","also","back","after","use","two",
            "how","our","work","first","well","way","even","new","want","because","any",
            "these","give","day","most","us","great","between","need","each","much","right",
            "here","still","own","find","long","very","after","thing","many","world","before",
            "should","may","through","while","where","more","around","never","small","last",
            "hand","high","keep","every","same","begin","might","show","always","next","early",
            "move","live","start","since","help","open","close","run","real","help","home",
            "best","both","side","part","point","end","head","turn","old","again","under",
            "let","call","few","big","must","off","line","house","number","place","water",
            "hello","please","thank","thanks","yes","sorry","okay","welcome","today","tomorrow",
        ])
    }

    /// Returns bonus score (0-25) for frequent words
    func bonus(_ word: String, language: String) -> Int {
        let lowered = word.lowercased()
        switch language {
        case "ru": return topWordsRU.contains(lowered) ? 25 : 0
        case "en": return topWordsEN.contains(lowered) ? 25 : 0
        default: return 0
        }
    }
}
